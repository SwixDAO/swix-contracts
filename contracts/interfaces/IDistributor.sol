// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.7.5;

interface IDistributor {
    function distribute() external;

    function bounty() external view returns (uint256);

    function retrieveBounty() external returns (uint256);

    function nextRewardAt(uint256 rate) external view returns (uint256);

    function nextRewardFor(address recipient) external view returns (uint256);

    function setBounty(uint256 newBounty) external;

    function addRecipient(address recipient, uint256 rewardRate) external;

    function removeRecipient(uint256 recipientIndex) external;

    function setAdjustment(
        uint256 recipientIndex,
        bool isAdd,
        uint256 newRate,
        uint256 newTarget
    ) external;
}
