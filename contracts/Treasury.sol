// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.7.5;

import "./libraries/SafeMath.sol";
import "./libraries/SafeERC20.sol";

import "./interfaces/IERC20.sol";
import "./interfaces/IERC20Metadata.sol";
import "./interfaces/ISWIX.sol";
import "./interfaces/IsSWIX.sol";
import "./interfaces/IBondingCalculator.sol";
import "./interfaces/ITreasury.sol";

import "./types/SwixAccessControlled.sol";

contract SwixTreasury is SwixAccessControlled, ITreasury {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;


    /* =====================================================
                            STRUCTS
     ===================================================== */

    enum STATUS {
        RESERVEDEPOSITOR,
        RESERVESPENDER,
        RESERVETOKEN,
        RESERVEMANAGER,
        LIQUIDITYDEPOSITOR,
        LIQUIDITYTOKEN,
        LIQUIDITYMANAGER,
        RESERVEDEBTOR,
        REWARDMANAGER,
        SSWIX
    }

    struct Queue {
        STATUS managing;
        address toPermit;
        address calculator;
        uint256 timelockEnd;
        bool nullify;
        bool executed;
    }

    /* =====================================================
                            IMMUTABLES
     ===================================================== */

    ISWIX public immutable SWIX;

    /// Timelock length for adding an address to role
    uint256 public immutable blocksNeededForQueue;
    

    /* =====================================================
                    PUBLiC STATE VARIABLES
     ===================================================== */

    IsSWIX public sSWIX;

    /// Array of all addresses per role
    mapping(STATUS => address[]) public registry;
    /// Mapping to check if address has a certain role
    mapping(STATUS => mapping(address => bool)) public permissions;
    /// Bond calculator for each reserve and liquidity token
    mapping(address => address) public bondCalculator;
    /// Debt limit per token bonded
    mapping(address => uint256) public debtLimit;

    /// Sum of all reserve tokens
    uint256 public totalReserves;
    /// Sum of all debt for reserve and liquidity bonds
    uint256 public totalDebt;

    Queue[] public permissionQueue;

    /// Toggle for enabling the timelock
    bool public timelockEnabled;
    /// Toggle if the Treasury contract have been initialized
    bool public initialized;

    uint256 public onChainGovernanceTimelock;


    /* =====================================================
                    INTERNAL STATE VARIABLES
     ===================================================== */

    // Error strings
    string internal notAccepted = "Treasury: not accepted";
    string internal notApproved = "Treasury: not approved";
    string internal invalidToken = "Treasury: invalid token";
    string internal insufficientReserves = "Treasury: insufficient reserves";


    /* =====================================================
                            CONSTRUCTOR
     ===================================================== */

    constructor(
        address setSwix,
        uint256 setTimelock,
        ISwixAuthority setAuthority
    )
        SwixAccessControlled(setAuthority)
    {
        require(setSwix != address(0), "Zero address: SWIX");

        SWIX = ISWIX(setSwix);

        timelockEnabled = false;
        initialized = false;
        blocksNeededForQueue = setTimelock;
    }


    /* =====================================================
                        STATUS FUNCTIONS
     ===================================================== */

    /// Allow approved address to deposit an asset for SWIX
    ///
    /// @param amount   uint256
    /// @param token    address
    /// @param profit   uint256
    ///
    /// @return swixAmount uint256
    function deposit(
        uint256 amount,
        address token,
        uint256 profit
    )
        external
        override
        returns (uint256 swixAmount)
    {
        if (permissions[STATUS.RESERVETOKEN][token]) {
            require(
                permissions[STATUS.RESERVEDEPOSITOR][msg.sender],
                notApproved
            );
        } else if (permissions[STATUS.LIQUIDITYTOKEN][token]) {
            require(
                permissions[STATUS.LIQUIDITYDEPOSITOR][msg.sender],
                notApproved
            );
        } else {
            revert(invalidToken);
        }

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        uint256 value = tokenValue(token, amount);
        // mint SWIX needed and store amount of rewards for distribution
        swixAmount = value.sub(profit);
        SWIX.mint(msg.sender, swixAmount);

        totalReserves = totalReserves.add(value);

        emit Deposit(token, amount, value);
    }

    /// Allow approved address to burn SWIX for reserves
    /// This function allows only approved addresses (DAO) to buy back tokens at a discount and burn them for reserves
    ///
    /// @param amount   uint256
    /// @param token    address
    function withdraw(uint256 amount, address token)
        external
        override
    {
        // Only reserves can be used for redemptions
        require(permissions[STATUS.RESERVETOKEN][token], notAccepted);
        // Only aproved addresses
        require(permissions[STATUS.RESERVESPENDER][msg.sender], notApproved);

        uint256 value = tokenValue(token, amount);
        SWIX.burnFrom(msg.sender, value);

        totalReserves = totalReserves.sub(value);

        IERC20(token).safeTransfer(msg.sender, amount);

        emit Withdrawal(token, amount, value);
    }

    /// Allow approved address to withdraw assets
    /// Function for allocators to put excess reserves to work, can be used to retrieve mistaken transfers
    ///
    /// @param token    address
    /// @param amount   uint256
    function manage(address token, uint256 amount)
        external
        override
    {
        if (permissions[STATUS.LIQUIDITYTOKEN][token]) {
            require(
                permissions[STATUS.LIQUIDITYMANAGER][msg.sender],
                notApproved
            );
        } else {
            require(
                permissions[STATUS.RESERVEMANAGER][msg.sender],
                notApproved
            );
        }

        // If the token is a reserve or liquidity asset only allow to take value equal to excess reserves
        if (
            permissions[STATUS.RESERVETOKEN][token] ||
            permissions[STATUS.LIQUIDITYTOKEN][token]
        ) {
            // Evaluate withdrawn token amount
            uint256 value = tokenValue(token, amount);
            require(value <= excessReserves(), insufficientReserves);
            totalReserves = totalReserves.sub(value);
        }
        // Transfer chosen to the sender
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Managed(token, amount);
    }

    /// Mint new SWIX using excess reserves
    ///
    /// @param recipient    address
    /// @param amount       uint256
    function mint(address recipient, uint256 amount)
        external
        override
    {
        require(permissions[STATUS.REWARDMANAGER][msg.sender], notApproved);
        require(amount <= excessReserves(), insufficientReserves);

        SWIX.mint(recipient, amount);

        emit Minted(msg.sender, recipient, amount);
    }


    /* =====================================================
                        GOVERNOR FUNCTIONS
     ===================================================== */
    
    /// Enables timelocks after initilization
    function initialize()
        external
        onlyGovernor
    {
        require(initialized == false, "Already initialized");
        timelockEnabled = true;
        initialized = true;
    }

    /// Takes inventory of all tracked assets
    /// Always consolidate to recognized reserves before audit
    function auditReserves()
        external
        onlyGovernor
    {
        uint256 reserves;
        address[] memory reserveToken = registry[STATUS.RESERVETOKEN];

        for (uint256 i = 0; i < reserveToken.length; i++) {
            if (permissions[STATUS.RESERVETOKEN][reserveToken[i]]) {
                reserves = reserves.add(
                    tokenValue(
                        reserveToken[i],
                        IERC20(reserveToken[i]).balanceOf(address(this))
                    )
                );
            }
        }

        address[] memory liquidityToken = registry[STATUS.LIQUIDITYTOKEN];

        for (uint256 i = 0; i < liquidityToken.length; i++) {
            if (permissions[STATUS.LIQUIDITYTOKEN][liquidityToken[i]]) {
                reserves = reserves.add(
                    tokenValue(
                        liquidityToken[i],
                        IERC20(liquidityToken[i]).balanceOf(address(this))
                    )
                );
            }
        }

        totalReserves = reserves;
        emit ReservesAudited(reserves);
    }

    /// Set max debt for address
    ///
    /// @param debtor   address
    /// @param limit    uint256
    function setDebtLimit(address debtor, uint256 limit)
        external
        onlyGovernor
    {
        debtLimit[debtor] = limit;
    }

    /// Enable permission from queue
    ///
    /// @param status STATUS
    /// @param newAddress address
    /// @param calculator address
    function enable(
        STATUS status,
        address newAddress,
        address calculator
    )
        external
        onlyGovernor
    {
        require(timelockEnabled == false, "Use queueTimelock");

        if (status == STATUS.SSWIX) {
            sSWIX = IsSWIX(newAddress);
        }
        else {
            permissions[status][newAddress] = true;

            if (status == STATUS.LIQUIDITYTOKEN) {
                bondCalculator[newAddress] = calculator;
            }

            (bool registered, ) = indexInRegistry(newAddress, status);

            if (!registered) {
                registry[status].push(newAddress);

                if (
                    status == STATUS.LIQUIDITYTOKEN ||
                    status == STATUS.RESERVETOKEN
                ) {
                    (bool reg, uint256 index) = indexInRegistry(
                        newAddress,
                        status
                    );
                    if (reg) {
                        delete registry[status][index];
                    }
                }
            }
        }

        emit Permissioned(newAddress, status, true);
    }


    /* =====================================================
                  GOVERNOR TIMELOCK FUNCTIONS
     ===================================================== */
    // These functions are used prior to enabling on-chain governance

    /// Queue address to receive permission
    ///
    /// @param status STATUS
    /// @param newAddress address
    /// @param calculator address
    function queueTimelock(
        STATUS status,
        address newAddress,
        address calculator
    )
        external
        onlyGovernor
    {
        require(newAddress != address(0));
        require(timelockEnabled == true, "Timelock is disabled, use enable");

        uint256 timelock = block.number.add(blocksNeededForQueue);

        if (
            status == STATUS.RESERVEMANAGER ||
            status == STATUS.LIQUIDITYMANAGER
        ) {
            timelock = block.number.add(blocksNeededForQueue.mul(2));
        }

        permissionQueue.push(
            Queue({
                managing: status,
                toPermit: newAddress,
                calculator: calculator,
                timelockEnd: timelock,
                nullify: false,
                executed: false
            })
        );

        emit PermissionQueued(status, newAddress);
    }

    /// Enable queued permission
    ///
    ///  @param queueIndex uint256
    function execute(uint256 queueIndex)
        external
    {
        require(timelockEnabled == true, "Timelock is disabled, use enable");

        Queue memory info = permissionQueue[queueIndex];

        require(!info.nullify, "Action has been nullified");
        require(!info.executed, "Action has already been executed");
        require(block.number >= info.timelockEnd, "Timelock not complete");

        if (info.managing == STATUS.SSWIX) {
            // 9
            sSWIX = IsSWIX(info.toPermit);
        }
        else {
            permissions[info.managing][info.toPermit] = true;

            if (info.managing == STATUS.LIQUIDITYTOKEN) {
                bondCalculator[info.toPermit] = info.calculator;
            }
            (bool registered, ) = indexInRegistry(info.toPermit, info.managing);
            if (!registered) {
                registry[info.managing].push(info.toPermit);

                if (info.managing == STATUS.LIQUIDITYTOKEN) {
                    (bool reg, uint256 index) = indexInRegistry(
                        info.toPermit,
                        STATUS.RESERVETOKEN
                    );
                    if (reg) {
                        delete registry[STATUS.RESERVETOKEN][index];
                    }
                }
                else if (info.managing == STATUS.RESERVETOKEN) {
                    (bool reg, uint256 index) = indexInRegistry(
                        info.toPermit,
                        STATUS.LIQUIDITYTOKEN
                    );
                    if (reg) {
                        delete registry[STATUS.LIQUIDITYTOKEN][index];
                    }
                }
            }
        }
        permissionQueue[queueIndex].executed = true;

        emit Permissioned(info.toPermit, info.managing, true);
    }

    /// Cancel timelocked action
    ///
    /// @param queueIndex uint256
    function nullify(uint256 queueIndex)
        external
        onlyGovernor
    {
        permissionQueue[queueIndex].nullify = true;
    }

    /// Disables timelocked functions
    function disableTimelock()
        external
        onlyGovernor
    {
        require(timelockEnabled == true, "timelock already disabled");

        if (
            onChainGovernanceTimelock != 0 &&
            onChainGovernanceTimelock <= block.number
        ) {
            timelockEnabled = false;
        }
        else {
            onChainGovernanceTimelock = block.number.add(
                blocksNeededForQueue.mul(7)
            ); // 7-day timelock
        }
    }


    /* =====================================================
                 GOVERNOR & GUARDIAN FUNCTIONS
     ===================================================== */
    
    /// Disable permission from address
    ///
    /// @param toDisable    address
    /// @param status       STATUS
    function disable(address toDisable, STATUS status)
        external
    {
        require(
            msg.sender == authority.governor() ||
                msg.sender == authority.guardian(),
            "Only governor or guardian"
        );
        permissions[status][toDisable] = false;
        emit Permissioned(toDisable, status, false);
    }


    /* =====================================================
                        VIEW FUNCTIONS
     ===================================================== */

    /// Returns excess reserves not backing tokens
    ///
    /// @return uint
    function excessReserves()
        public
        view
        override
        returns (uint256)
    {
        return totalReserves.sub(SWIX.totalSupply().sub(totalDebt));
    }

    /// Returns SWIX valuation of asset
    ///
    /// @param token address
    /// @param amount uint256
    ///
    /// @return value uint256
    function tokenValue(address token, uint256 amount)
        public
        view
        override
        returns (uint256 value)
    {
        value = amount.mul(10**IERC20Metadata(address(SWIX)).decimals()).div(
            10**IERC20Metadata(token).decimals()
        );

        if (permissions[STATUS.LIQUIDITYTOKEN][token]) {
            value = IBondingCalculator(bondCalculator[token]).valuation(
                token,
                amount
            );
        }
    }

    /// Returns supply metric that cannot be manipulated by debt
    ///
    /// @dev use this any time you need to query supply
    ///
    /// @return uint256
    function baseSupply()
        external
        view
        override
        returns (uint256)
    {
        return SWIX.totalSupply();
    }

    /// Check if registry contains address
    ///
    /// @param checkedAddress   address
    /// @param status           STATUS
    ///
    /// @return (bool, uint256)
    function indexInRegistry(address checkedAddress, STATUS status)
        public
        view
        returns (bool, uint256)
    {
        address[] memory entries = registry[status];
        for (uint256 i = 0; i < entries.length; i++) {
            if (checkedAddress == entries[i]) {
                return (true, i);
            }
        }
        return (false, 0);
    }

    
    /* =====================================================
                            EVENTS
    ===================================================== */

    event Deposit(address indexed token, uint256 amount, uint256 value);
    event Withdrawal(address indexed token, uint256 amount, uint256 value);
    event Managed(address indexed token, uint256 amount);
    event ReservesAudited(uint256 indexed totalReserves);
    event Minted(
        address indexed caller,
        address indexed recipient,
        uint256 amount
    );
    event PermissionQueued(STATUS indexed status, address queued);
    event Permissioned(address addr, STATUS indexed status, bool result);
}
