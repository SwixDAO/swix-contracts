// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.7.5;

import "./interfaces/ISwixAuthority.sol";

import "./types/SwixAccessControlled.sol";

contract SwixAuthority is ISwixAuthority, SwixAccessControlled {
    
    /* =====================================================
                        STATE VARIABLES
     ===================================================== */

    address public override governor;

    address public override guardian;

    address public override policy;

    address public override vault;

    address public pendingGovernor;

    address public pendingGuardian;

    address public pendingPolicy;

    address public pendingVault;


    /* =====================================================
                            CONSTRUCTOR
     ===================================================== */

    constructor(
        address setGovernor,
        address setGuardian,
        address setPolicy,
        address setVault
    )
        SwixAccessControlled(ISwixAuthority(address(this)))
    {
        governor = setGovernor;
        emit GovernorPushed(address(0), governor, true);

        guardian = setGuardian;
        emit GuardianPushed(address(0), guardian, true);

        policy = setPolicy;
        emit PolicyPushed(address(0), policy, true);

        vault = setVault;
        emit VaultPushed(address(0), vault, true);
    }


    /* =====================================================
                        GOVERNOR FUNCTIONS
     ===================================================== */

    function pushGovernor(address newGovernor, bool effectiveImmediately)
        external
        onlyGovernor
    {
        if (effectiveImmediately) governor = newGovernor;
        pendingGovernor = newGovernor;
        emit GovernorPushed(governor, pendingGovernor, effectiveImmediately);
    }

    function pushGuardian(address newGuardian, bool effectiveImmediately)
        external
        onlyGovernor
    {
        if (effectiveImmediately) guardian = newGuardian;
        pendingGuardian = newGuardian;
        emit GuardianPushed(guardian, pendingGuardian, effectiveImmediately);
    }

    function pushPolicy(address newPolicy, bool effectiveImmediately)
        external
        onlyGovernor
    {
        if (effectiveImmediately) policy = newPolicy;
        pendingPolicy = newPolicy;
        emit PolicyPushed(policy, pendingPolicy, effectiveImmediately);
    }

    function pushVault(address newVault, bool effectiveImmediately)
        external
        onlyGovernor
    {
        if (effectiveImmediately) vault = newVault;
        pendingVault = newVault;
        emit VaultPushed(vault, pendingVault, effectiveImmediately);
    }

    /* =====================================================
                      PENDING ROLES FUNCTIONS
     ===================================================== */

    function updateGovernor() external {
        require(msg.sender == pendingGovernor, "!newGovernor");
        emit GovernorUpdated(governor, pendingGovernor);
        governor = pendingGovernor;
    }

    function updateGuardian() external {
        require(msg.sender == pendingGuardian, "!newGuard");
        emit GuardianUpdated(guardian, pendingGuardian);
        guardian = pendingGuardian;
    }

    function updatePolicy() external {
        require(msg.sender == pendingPolicy, "!newPolicy");
        emit PolicyUpdated(policy, pendingPolicy);
        policy = pendingPolicy;
    }

    function updateVault() external {
        require(msg.sender == pendingVault, "!newVault");
        emit VaultUpdated(vault, pendingVault);
        vault = pendingVault;
    }
}
