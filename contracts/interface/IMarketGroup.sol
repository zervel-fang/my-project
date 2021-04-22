// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.17;

interface IMarketGroup {
	function addGroup(address _addr) external;

	function isGroup(address _addr) external view returns (bool);

	function getCount() external view returns (uint256);
}
