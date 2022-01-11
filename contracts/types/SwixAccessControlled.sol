// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.7.5;

import "../interfaces/ISwixAuthority.sol";

abstract contract SwixAccessControlled {
    
    /* =====================================================
                        STATE VARIABLES
     ===================================================== */

    ISwixAuthority public authority;

    string UNAUTHORIZED = "UNAUTHORIZED";


    /* =====================================================
                        MODIFIERS
     ===================================================== */

    modifier onlyGovernor() {
        require(msg.sender == authority.governor(), UNAUTHORIZED);
        _;
    }

    modifier onlyGuardian() {
        require(msg.sender == authority.guardian(), UNAUTHORIZED);
        _;
    }

    modifier onlyPolicy() {
        require(msg.sender == authority.policy(), UNAUTHORIZED);
        _;
    }

    modifier onlyVault() {
        require(msg.sender == authority.vault(), UNAUTHORIZED);
        _;
    }


    /* =====================================================
                        CONSTRUCTOR
     ===================================================== */

    constructor(ISwixAuthority _authority) {
        authority = _authority;
        emit AuthorityUpdated(_authority);
    }


    /* =====================================================
                        GOVERNOR FUNCTIONS
     ===================================================== */

    function setAuthority(ISwixAuthority newAuthority)
        external
        onlyGovernor
    {
        authority = newAuthority;
        emit AuthorityUpdated(newAuthority);
    }


    /* =====================================================
                            EVENTS
     ===================================================== */

    event AuthorityUpdated(ISwixAuthority indexed authority);
}
