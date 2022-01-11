// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.7.5;

interface ITreasury {
    function deposit(
        uint256 amount,
        address token,
        uint256 profit
    ) external returns (uint256);

    function withdraw(uint256 amount, address token) external;

    function tokenValue(address token, uint256 amount)
        external
        view
        returns (uint256 value);

    function mint(address recipient, uint256 amount) external;

    function manage(address token, uint256 amount) external;
    
    function excessReserves() external view returns (uint256);

    function baseSupply() external view returns (uint256);
}
