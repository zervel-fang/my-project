pragma solidity 0.5.17;

import {Decimals} from "contracts/src/common/libs/Decimals.sol";
import {IPolicy} from "contracts/interface/IPolicy.sol";

contract PolicyTest1 is IPolicy {
	using Decimals for uint256;

	function rewards(uint256 _lockups, uint256 _assets)
		external
		view
		returns (uint256)
	{
		return _lockups + _assets;
	}

	function holdersShare(uint256 _amount, uint256 _lockups)
		external
		view
		returns (uint256)
	{
		uint256 sum = _amount + _lockups;
		uint256 share = _lockups.outOf(sum);
		return _amount - (_amount * share).divBasis();
	}

	function authenticationFee(uint256 _assets, uint256 _propertyLockups)
		external
		view
		returns (uint256)
	{
		return _assets + _propertyLockups - 1;
	}

	function marketApproval(uint256 _agree, uint256 _opposite)
		external
		view
		returns (bool)
	{
		if (_agree + _opposite < 10000) {
			return false;
		}
		return _agree > _opposite;
	}

	function policyApproval(uint256 _agree, uint256 _opposite)
		external
		view
		returns (bool)
	{
		if (_agree + _opposite < 10000) {
			return false;
		}
		return _agree > _opposite;
	}

	function marketVotingBlocks() external view returns (uint256) {
		return 10;
	}

	function policyVotingBlocks() external view returns (uint256) {
		return 20;
	}
}
