// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.7.5;

import "./libraries/SafeMath.sol";
import "./libraries/FixedPoint.sol";
import "./libraries/Address.sol";
import "./libraries/SafeERC20.sol";

import "./interfaces/IERC20Metadata.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IBondingCalculator.sol";
import "./interfaces/IUniswapV2ERC20.sol";
import "./interfaces/IUniswapV2Pair.sol";

contract SwixBondingCalculator is IBondingCalculator {
    using FixedPoint for *;
    using SafeMath for uint256;

    /* =====================================================
                          IMMUTABLES
     ===================================================== */

    IERC20 internal immutable SWIX;


    /* =====================================================
                          CONSTRUCTOR
     ===================================================== */
    constructor(address setSwix) {
        require(setSwix != address(0), "Zero address: SWIX");

        SWIX = IERC20(setSwix);
    }


    /* =====================================================
                        PUBLIC FUNCTIONS
     ===================================================== */

    function getKValue(address pair)
        public
        view
        returns (uint256 k_)
    {
        uint256 token0 = IERC20Metadata(IUniswapV2Pair(pair).token0())
            .decimals();
        uint256 token1 = IERC20Metadata(IUniswapV2Pair(pair).token1())
            .decimals();
        uint256 decimals = token0.add(token1).sub(
            IERC20Metadata(pair).decimals()
        );

        (uint256 reserve0, uint256 reserve1, ) = IUniswapV2Pair(pair)
            .getReserves();
        k_ = reserve0.mul(reserve1).div(10**decimals);
    }

    function getTotalValue(address pair)
        public
        view
        returns (uint256 value)
    {
        value = getKValue(pair).sqrrt().mul(2);
    }


    /* =====================================================
                        EXTERNAL FUNCTIONS
     ===================================================== */

    function valuation(address pair, uint256 amount)
        external
        view
        override
        returns (uint256 value)
    {
        uint256 totalValue = getTotalValue(pair);
        uint256 totalSupply = IUniswapV2Pair(pair).totalSupply();

        value = totalValue
            .mul(FixedPoint.fraction(amount, totalSupply).decode112with18())
            .div(1e18);
    }

    function markdown(address pair)
        external
        view
        override
        returns (uint256)
    {
        (uint256 reserve0, uint256 reserve1, ) = IUniswapV2Pair(pair)
            .getReserves();

        uint256 reserve;
        if (IUniswapV2Pair(pair).token0() == address(SWIX)) {
            reserve = reserve1;
        } else {
            require(
                IUniswapV2Pair(pair).token1() == address(SWIX),
                "Invalid pair"
            );
            reserve = reserve0;
        }
        return
            reserve.mul(2 * (10**IERC20Metadata(address(SWIX)).decimals())).div(
                getTotalValue(pair)
            );
    }
}
