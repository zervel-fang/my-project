pragma solidity 0.5.17;

import {IAddressConfig} from "contracts/interface/IAddressConfig.sol";
import {UsingConfig} from "contracts/src/common/config/UsingConfig.sol";

contract UsingConfigTest is UsingConfig {
	constructor(address _config) public UsingConfig(_config) {}

	function getToken() external view returns (address) {
		return config().token();
	}
}
