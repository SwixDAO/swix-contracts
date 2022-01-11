// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.7.5;

import "./libraries/SafeMath.sol";

import "./interfaces/IERC20.sol";
import "./interfaces/ISWIX.sol";
import "./interfaces/IERC20Permit.sol";

import "./types/ERC20Permit.sol";
import "./types/SwixAccessControlled.sol";

contract SwixToken is
    ERC20Permit,
    ISWIX,
    SwixAccessControlled
{
    using SafeMath for uint256;


    /* =====================================================
                          CONSTRUCTOR
     ===================================================== */

    constructor(ISwixAuthority setAuthority)
        ERC20("Swix", "SWIX", 18)
        ERC20Permit("Swix")
        SwixAccessControlled(setAuthority)
    {}


    /* =====================================================
                        USER FUNCTIONS
     ===================================================== */

    function burn(uint256 amount)
        external
        override
    {
        _burn(msg.sender, amount);
    }

    function burnFrom(address account, uint256 amount)
        external
        override
    {
        _burnFrom(account, amount);
    }


    /* =====================================================
                        VAULT FUNCTIONS
     ===================================================== */

    function mint(address account, uint256 amount)
        external
        override
        onlyVault
    {
        _mint(account, amount);
    }


    /* =====================================================
                        INTERNAL FUNCTIONS
     ===================================================== */

    function _burnFrom(address account, uint256 amount)
        internal
    {
        uint256 decreasedAllowance_ = allowance(account, msg.sender).sub(
            amount,
            "ERC20: burn amount exceeds allowance"
        );

        _approve(account, msg.sender, decreasedAllowance_);
        _burn(account, amount);
    }
}
