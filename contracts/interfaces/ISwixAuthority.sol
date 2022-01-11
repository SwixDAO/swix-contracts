// SPDX-License-Identifier: AGPL-3.0
pragma solidity =0.7.5;

interface ISwixAuthority {
    function governor() external view returns (address);

    function guardian() external view returns (address);

    function policy() external view returns (address);

    function vault() external view returns (address);

    event GovernorPushed(
        address indexed from,
        address indexed to,
        bool effectiveImmediately
    );
    event GuardianPushed(
        address indexed from,
        address indexed to,
        bool effectiveImmediately
    );
    event PolicyPushed(
        address indexed from,
        address indexed to,
        bool effectiveImmediately
    );
    event VaultPushed(
        address indexed from,
        address indexed to,
        bool effectiveImmediately
    );

    event GovernorUpdated(address indexed from, address indexed to);
    event GuardianUpdated(address indexed from, address indexed to);
    event PolicyUpdated(address indexed from, address indexed to);
    event VaultUpdated(address indexed from, address indexed to);
}
