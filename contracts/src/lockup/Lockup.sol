pragma solidity ^0.5.0;

// prettier-ignore
import {ERC20Mintable} from "@openzeppelin/contracts/token/ERC20/ERC20Mintable.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {Decimals} from "contracts/src/common/libs/Decimals.sol";
import {UsingValidator} from "contracts/src/common/validate/UsingValidator.sol";
import {Property} from "contracts/src/property/Property.sol";
import {UsingConfig} from "contracts/src/common/config/UsingConfig.sol";
import {LockupStorage} from "contracts/src/lockup/LockupStorage.sol";
import {Policy} from "contracts/src/policy/Policy.sol";
import {IAllocator} from "contracts/src/allocator/IAllocator.sol";
import {IVoteTimes} from "contracts/src/vote/times/IVoteTimes.sol";
import {ILockup} from "contracts/src/lockup/ILockup.sol";

contract Lockup is ILockup, UsingConfig, UsingValidator, LockupStorage {
	using SafeMath for uint256;
	using Decimals for uint256;
	event Lockedup(address _from, address _property, uint256 _value);

	// solium-disable-next-line no-empty-blocks
	constructor(address _config) public UsingConfig(_config) {}

	function lockup(
		address _from,
		address _property,
		uint256 _value
	) external {
		addressValidator().validateAddress(msg.sender, config().token());
		addressValidator().validateGroup(_property, config().propertyGroup());
		require(_value != 0, "illegal lockup value");

		bool isWaiting = getStorageWithdrawalStatus(_property, _from) != 0;
		require(isWaiting == false, "lockup is already canceled");
		if (getStorageLastBlockNumber(_property) == 0) {
			// Set the block that has been locked-up for the first time as the starting block.
			setStorageLastBlockNumber(_property, block.number);
		}
		updatePendingInterestWithdrawal(_property, _from);
		(, uint256 last) = _calculateWithdrawableInterestAmount(
			_property,
			_from
		);
		updateLastPriceForProperty(_property, _from, last);
		updateValues(true, _from, _property, _value);
		emit Lockedup(_from, _property, _value);
	}

	function cancel(address _property) external {
		addressValidator().validateGroup(_property, config().propertyGroup());

		require(hasValue(_property, msg.sender), "dev token is not locked");
		bool isWaiting = getStorageWithdrawalStatus(_property, msg.sender) != 0;
		require(isWaiting == false, "lockup is already canceled");
		uint256 blockNumber = Policy(config().policy()).lockUpBlocks();
		blockNumber = blockNumber.add(block.number);
		setStorageWithdrawalStatus(_property, msg.sender, blockNumber);
	}

	function withdraw(address _property) external {
		addressValidator().validateGroup(_property, config().propertyGroup());

		require(possible(_property, msg.sender), "waiting for release");
		uint256 lockedUpValue = getStorageValue(_property, msg.sender);
		require(lockedUpValue != 0, "dev token is not locked");
		updatePendingInterestWithdrawal(_property, msg.sender);
		Property(_property).withdraw(msg.sender, lockedUpValue);
		updateValues(false, msg.sender, _property, lockedUpValue);
		setStorageValue(_property, msg.sender, 0);
		setStorageWithdrawalStatus(_property, msg.sender, 0);
	}

	function getCumulativeLockedUpUnitAndBlock(address _property)
		private
		view
		returns (uint256 _unit, uint256 _block)
	{
		(
			uint256 unit,
			uint256 lastBlock
		) = getStorageCumulativeLockedUpUnitAndBlock(_property);
		if (lastBlock > 0) {
			return (unit, lastBlock);
		}
		// When lastBlock is 0, CumulativeLockedUpUnitAndBlock is not saved yet so failback to AllValue or PropertyValue.
		unit = _property == address(0)
			? getStorageAllValue()
			: getStoragePropertyValue(_property);
		// Assign lastBlock as DIP4GenesisBlock because when AllValue or PropertyValue is not 0, already locked-up when started DIP4.
		lastBlock = getStorageDIP4GenesisBlock();
		return (unit, lastBlock);
	}

	function getCumulativeLockedUp(address _property)
		public
		view
		returns (
			uint256 _value,
			uint256 _unit,
			uint256 _block
		)
	{
		(uint256 unit, uint256 lastBlock) = getCumulativeLockedUpUnitAndBlock(
			_property
		);
		uint256 lastValue = getStorageCumulativeLockedUpValue(_property);
		return (
			lastValue.add(unit.mul(block.number.sub(lastBlock))),
			unit,
			lastBlock
		);
	}

	function getCumulativeLockedUpAll()
		public
		view
		returns (
			uint256 _value,
			uint256 _unit,
			uint256 _block
		)
	{
		return getCumulativeLockedUp(address(0));
	}

	function updateCumulativeLockedUp(
		bool _addition,
		address _property,
		uint256 _unit
	) private {
		address zero = address(0);
		(uint256 lastValue, uint256 lastUnit, ) = getCumulativeLockedUp(
			_property
		);
		(uint256 lastValueAll, uint256 lastUnitAll, ) = getCumulativeLockedUp(
			zero
		);
		setStorageCumulativeLockedUpValue(
			_property,
			_addition ? lastValue.add(_unit) : lastValue.sub(_unit)
		);
		setStorageCumulativeLockedUpValue(
			zero,
			_addition ? lastValueAll.add(_unit) : lastValueAll.sub(_unit)
		);
		setStorageCumulativeLockedUpUnitAndBlock(
			_property,
			_addition ? lastUnit.add(_unit) : lastUnit.sub(_unit),
			block.number
		);
		setStorageCumulativeLockedUpUnitAndBlock(
			zero,
			_addition ? lastUnitAll.add(_unit) : lastUnitAll.sub(_unit),
			block.number
		);
	}

	function update() public {
		(uint256 _nextRewards, uint256 _amount) = dry();
		setStorageCumulativeGlobalRewards(_nextRewards);
		setStorageLastSameRewardsAmountAndBlock(_amount, block.number);
	}

	function updateLastPriceForProperty(
		address _property,
		address _user,
		uint256 _lastInterest
	) private {
		setStorageLastCumulativeGlobalReward(_property, _user, _lastInterest);
		setStorageLastBlockNumber(_property, block.number);
	}

	function validateTargetPeriod(address _property) private {
		(uint256 begin, uint256 end) = term(_property);
		uint256 blocks = end.sub(begin);
		require(
			blocks == 0 ||
				IVoteTimes(config().voteTimes()).validateTargetPeriod(
					_property,
					begin,
					end
				),
			"now abstention penalty"
		);
	}

	function term(address _property)
		private
		view
		returns (uint256 begin, uint256 end)
	{
		return (getStorageLastBlockNumber(_property), block.number);
	}

	function dry()
		private
		view
		returns (uint256 _nextRewards, uint256 _amount)
	{
		uint256 rewardsAmount = IAllocator(config().allocator())
			.calculateMaxRewardsPerBlock();
		(
			uint256 lastAmount,
			uint256 lastBlock
		) = getStorageLastSameRewardsAmountAndBlock();
		uint256 lastMaxRewards = lastAmount == rewardsAmount
			? rewardsAmount
			: lastAmount;

		uint256 blocks = lastBlock > 0 ? block.number.sub(lastBlock) : 0;
		uint256 additionalRewards = lastMaxRewards.mul(blocks);
		uint256 nextRewards = getStorageCumulativeGlobalRewards().add(
			additionalRewards
		);
		return (nextRewards, rewardsAmount);
	}

	function difference(address _property, uint256 _lastReward)
		public
		view
		returns (
			uint256 _reward,
			uint256 _holdersAmount,
			uint256 _holdersPrice,
			uint256 _interestAmount,
			uint256 _interestPrice
		)
	{
		(uint256 rewards, ) = dry();
		(uint256 valuePerProperty, , ) = getCumulativeLockedUp(_property);
		(uint256 valueAll, , ) = getCumulativeLockedUpAll();
		uint256 propertyRewards = rewards.sub(_lastReward).mul(
			valuePerProperty.mulBasis().outOf(valueAll)
		);
		uint256 lockedUpPerProperty = getStoragePropertyValue(_property);
		uint256 totalSupply = ERC20Mintable(_property).totalSupply();
		uint256 holders = Policy(config().policy()).holdersShare(
			propertyRewards,
			lockedUpPerProperty
		);
		uint256 interest = propertyRewards.sub(holders);
		return (
			rewards,
			holders,
			holders.div(totalSupply),
			interest,
			lockedUpPerProperty > 0 ? interest.div(lockedUpPerProperty) : 0
		);
	}

	function next(address _property)
		public
		view
		returns (
			uint256 _holders,
			uint256 _interest,
			uint256 _holdersPrice,
			uint256 _interestPrice
		)
	{
		(uint256 nextRewards, ) = dry();
		(uint256 valuePerProperty, , ) = getCumulativeLockedUp(_property);
		(uint256 valueAll, , ) = getCumulativeLockedUpAll();
		uint256 share = valuePerProperty.mulBasis().outOf(valueAll);
		uint256 propertyRewards = nextRewards.mul(share);
		uint256 lockedUp = getStoragePropertyValue(_property);
		uint256 holders = Policy(config().policy()).holdersShare(
			propertyRewards,
			lockedUp
		);
		uint256 interest = propertyRewards.sub(holders);
		uint256 holdersPrice = holders.div(
			ERC20Mintable(_property).totalSupply()
		);
		uint256 interestPrice = lockedUp > 0 ? interest.div(lockedUp) : 0;
		return (holders, interest, holdersPrice, interestPrice);
	}

	function _calculateInterestAmount(address _property, address _user)
		private
		view
		returns (uint256 _amount, uint256 _interest)
	{
		uint256 last = getStorageLastCumulativeGlobalReward(_property, _user);
		(uint256 nextReward, , , , uint256 price) = difference(_property, last);
		uint256 lockedUpPerAccount = getStorageValue(_property, _user);
		uint256 amount = price.mul(lockedUpPerAccount);
		uint256 result = amount > 0 ? amount.divBasis().divBasis() : 0;
		return (result, nextReward);
	}

	function _calculateWithdrawableInterestAmount(
		address _property,
		address _user
	) private view returns (uint256 _amount, uint256 _reward) {
		uint256 pending = getStoragePendingInterestWithdrawal(_property, _user);
		uint256 legacy = __legacyWithdrawableInterestAmount(_property, _user);
		(uint256 amount, uint256 reward) = _calculateInterestAmount(
			_property,
			_user
		);
		uint256 withdrawableAmount = amount
			.add(pending) // solium-disable-next-line indentation
			.add(legacy);
		return (withdrawableAmount, reward);
	}

	function calculateWithdrawableInterestAmount(
		address _property,
		address _user
	) public view returns (uint256) {
		(uint256 amount, ) = _calculateWithdrawableInterestAmount(
			_property,
			_user
		);
		return amount;
	}

	function withdrawInterest(address _property) external {
		addressValidator().validateGroup(_property, config().propertyGroup());

		validateTargetPeriod(_property);
		(uint256 value, uint256 last) = _calculateWithdrawableInterestAmount(
			_property,
			msg.sender
		);
		require(value > 0, "your interest amount is 0");
		setStoragePendingInterestWithdrawal(_property, msg.sender, 0);
		ERC20Mintable erc20 = ERC20Mintable(config().token());
		updateLastPriceForProperty(_property, msg.sender, last);
		__updateLegacyWithdrawableInterestAmount(_property, msg.sender);
		require(erc20.mint(msg.sender, value), "dev mint failed");
		update();
	}

	function updateValues(
		bool _addition,
		address _account,
		address _property,
		uint256 _value
	) private {
		if (_addition) {
			updateCumulativeLockedUp(true, _property, _value);
			addAllValue(_value);
			addPropertyValue(_property, _value);
			addValue(_property, _account, _value);
		} else {
			updateCumulativeLockedUp(false, _property, _value);
			subAllValue(_value);
			subPropertyValue(_property, _value);
		}
		update();
	}

	function getAllValue() external view returns (uint256) {
		return getStorageAllValue();
	}

	function addAllValue(uint256 _value) private {
		uint256 value = getStorageAllValue();
		value = value.add(_value);
		setStorageAllValue(value);
	}

	function subAllValue(uint256 _value) private {
		uint256 value = getStorageAllValue();
		value = value.sub(_value);
		setStorageAllValue(value);
	}

	function getValue(address _property, address _sender)
		external
		view
		returns (uint256)
	{
		return getStorageValue(_property, _sender);
	}

	function addValue(
		address _property,
		address _sender,
		uint256 _value
	) private {
		uint256 value = getStorageValue(_property, _sender);
		value = value.add(_value);
		setStorageValue(_property, _sender, value);
	}

	function hasValue(address _property, address _sender)
		private
		view
		returns (bool)
	{
		uint256 value = getStorageValue(_property, _sender);
		return value != 0;
	}

	function getPropertyValue(address _property)
		external
		view
		returns (uint256)
	{
		return getStoragePropertyValue(_property);
	}

	function addPropertyValue(address _property, uint256 _value) private {
		uint256 value = getStoragePropertyValue(_property);
		value = value.add(_value);
		setStoragePropertyValue(_property, value);
	}

	function subPropertyValue(address _property, uint256 _value) private {
		uint256 value = getStoragePropertyValue(_property);
		uint256 nextValue = value.sub(_value);
		setStoragePropertyValue(_property, nextValue);
	}

	function updatePendingInterestWithdrawal(address _property, address _user)
		private
	{
		(uint256 withdrawableAmount, ) = _calculateWithdrawableInterestAmount(
			_property,
			_user
		);
		setStoragePendingInterestWithdrawal(
			_property,
			_user,
			withdrawableAmount
		);
		__updateLegacyWithdrawableInterestAmount(_property, _user);
	}

	function possible(address _property, address _from)
		private
		view
		returns (bool)
	{
		uint256 blockNumber = getStorageWithdrawalStatus(_property, _from);
		if (blockNumber == 0) {
			return false;
		}
		if (blockNumber <= block.number) {
			return true;
		} else {
			if (Policy(config().policy()).lockUpBlocks() == 1) {
				return true;
			}
		}
		return false;
	}

	function __legacyWithdrawableInterestAmount(
		address _property,
		address _user
	) private view returns (uint256) {
		uint256 _last = getStorageLastInterestPrice(_property, _user);
		uint256 price = getStorageInterestPrice(_property);
		uint256 priceGap = price.sub(_last);
		uint256 lockedUpValue = getStorageValue(_property, _user);
		uint256 value = priceGap.mul(lockedUpValue);
		return value.divBasis();
	}

	function __updateLegacyWithdrawableInterestAmount(
		address _property,
		address _user
	) private {
		uint256 interestPrice = getStorageInterestPrice(_property);
		if (getStorageLastInterestPrice(_property, _user) != interestPrice) {
			setStorageLastInterestPrice(_property, _user, interestPrice);
		}
	}

	function setDIP4GenesisBlock(uint256 _block) external onlyOwner {
		setStorageDIP4GenesisBlock(_block);
	}
}
