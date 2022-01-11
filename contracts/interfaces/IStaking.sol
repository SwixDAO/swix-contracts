// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.7.5;

interface IStaking {
    function stake(
        address to,
        uint256 amount,
        bool claimNow
    ) external returns (uint256);

    function claim(address recipient)
        external
        returns (uint256);

    function forfeit() external returns (uint256);

    function toggleLock() external;

    function unstake(
        address to,
        uint256 amount,
        bool trigger
    ) external returns (uint256);

    function rebase() external;

    function index() external view returns (uint256);

    function totalStaked() external view returns (uint256);

    function supplyInWarmup() external view returns (uint256);
}
