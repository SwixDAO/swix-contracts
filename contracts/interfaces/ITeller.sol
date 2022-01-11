// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.7.5;

interface ITeller {
    function newBond(
        address bonder,
        address bondToken,
        uint256 bondTokenPaid,
        uint256 payout,
        uint256 expires,
        address frontEndOperator
    ) external returns (uint256 userBondIndex);

    function redeemAll(address bonder) external returns (uint256);

    function redeem(address bonder, uint256[] memory userBondIndexes)
        external
        returns (uint256);

    function getFrontEndReward() external;

    function setFrontEndReward(uint256 reward) external;

    function updateUserBondsIndexes(address bonder) external;

    function pendingFor(address bonder, uint256 index)
        external
        view
        returns (uint256);

    function pendingForIndexes(address bonder, uint256[] memory userBondIndexes)
        external
        view
        returns (uint256 pending);

    function totalPendingFor(address bonder)
        external
        view
        returns (uint256 pending);

    function percentVestedFor(address bonder, uint256 index)
        external
        view
        returns (uint256 percentVested);
}
