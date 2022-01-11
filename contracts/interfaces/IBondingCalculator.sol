// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.7.5;

interface IBondingCalculator {
    function markdown(address pair) external view returns (uint256);

    function valuation(address pair, uint256 amount)
        external
        view
        returns (uint256 value);
}
