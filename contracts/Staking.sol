// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.7.5;

import "./libraries/SafeMath.sol";
import "./libraries/SafeERC20.sol";

import "./interfaces/IERC20.sol";
import "./interfaces/IsSWIX.sol";
import "./interfaces/IDistributor.sol";

import "./types/SwixAccessControlled.sol";

contract SwixStaking is SwixAccessControlled {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IsSWIX;


    /* =====================================================
                            STRUCTS
    ===================================================== */

    struct Epoch {
        // in seconds
        uint256 length;
        // since inception
        uint256 number;
        // timestamper;
        uint256 end;
        // amount
        uint256 distribute;
    }

    struct Claim {
        // if forfeiting
        uint256 deposit;
        // staked balance
        uint256 gons;
        // end of warmup period
        uint256 expiry;
        // prevents malicious delays for claim
        bool lock;
    }


    /* =====================================================
                            IMMUTABLES
    ===================================================== */

    /// Swix Token Contract
    IERC20 public immutable SWIX;
    /// Staked Swix Token Contract
    IsSWIX public immutable sSWIX;


    /* =====================================================
                        STATE VARIABLES
    ===================================================== */

    Epoch public epoch;

    IDistributor public distributor;

    mapping(address => Claim) public warmupInfo;
    uint256 public warmupPeriod;
    uint256 private gonsInWarmup;


    /* =====================================================
                            CONSTRUCTOR
    ===================================================== */

    constructor(
        address setSwix,
        address setSSwix,
        uint256 setEpochLength,
        uint256 setFirstEpochNumber,
        uint256 setFirstEpochTime,
        ISwixAuthority setAuthority
    )
        SwixAccessControlled(setAuthority)
    {
        require(setSwix != address(0), "Zero address: SWIX");
        require(setSSwix != address(0), "Zero address: sSWIX");

        SWIX = IERC20(setSwix);
        sSWIX = IsSWIX(setSSwix);

        epoch = Epoch({
            length: setEpochLength,
            number: setFirstEpochNumber,
            end: setFirstEpochTime,
            distribute: 0
        });
    }


    /* =====================================================
                        USER FUNCTIONS
    ===================================================== */

    /// Stake SWIX to enter warmup
    ///
    /// @param receiver address
    /// @param amount uint
    /// @param claimNow bool
    ///
    /// @return uint
    function stake(
        address receiver,
        uint256 amount,
        bool claimNow
    )
        external
        returns (uint256)
    {
        SWIX.safeTransferFrom(msg.sender, address(this), amount);
        // add bounty if rebase occurred
        amount = amount.add(rebase());

        if (claimNow && warmupPeriod == 0) {
            return _send(receiver, amount);
        }
        else {
            Claim memory info = warmupInfo[receiver];
            if (!info.lock) {
                require(
                    receiver == msg.sender,
                    "External deposits for account are locked"
                );
            }

            warmupInfo[receiver] = Claim({
                deposit: info.deposit.add(amount),
                gons: info.gons.add(sSWIX.gonsForBalance(amount)),
                expiry: epoch.number.add(warmupPeriod),
                lock: info.lock
            });

            gonsInWarmup = gonsInWarmup.add(sSWIX.gonsForBalance(amount));

            return amount;
        }
    }

    /// Retrieve stake from warmup
    ///
    /// @param receiver address
    ///
    /// @return uint
    function claim(address receiver)
        public
        returns (uint256)
    {
        Claim memory info = warmupInfo[receiver];

        if (!info.lock) {
            require(
                receiver == msg.sender,
                "External claims for account are locked"
            );
        }

        if (epoch.number >= info.expiry && info.expiry != 0) {
            delete warmupInfo[receiver];

            gonsInWarmup = gonsInWarmup.sub(info.gons);

            return _send(receiver, sSWIX.balanceForGons(info.gons));
        }

        return 0;
    }

    /// Forfeit stake and retrieve SWIX
    ///
    /// @return uint
    function forfeit()
        external
        returns (uint256)
    {
        Claim memory info = warmupInfo[msg.sender];
        delete warmupInfo[msg.sender];

        gonsInWarmup = gonsInWarmup.sub(info.gons);

        SWIX.safeTransfer(msg.sender, info.deposit);

        return info.deposit;
    }

    /// Prevent new deposits or claims from external address
    /// (protection from malicious activity)
    function toggleLock() external {
        warmupInfo[msg.sender].lock = !warmupInfo[msg.sender].lock;
    }

    /// Redeem sSWIX for SWIXs
    ///
    /// @param receiver address
    /// @param amount uint
    /// @param trigger bool
    ///
    /// @return swixAmount uint
    function unstake(
        address receiver,
        uint256 amount,
        bool trigger
    )
        external
        returns (uint256 swixAmount)
    {
        swixAmount = amount;
        uint256 bounty;
        if (trigger) {
            bounty = rebase();
        }

        sSWIX.safeTransferFrom(msg.sender, address(this), amount);
        swixAmount = swixAmount.add(bounty);

        require(
            swixAmount <= SWIX.balanceOf(address(this)),
            "Insufficient SWIX balance in contract"
        );
        SWIX.safeTransfer(receiver, swixAmount);
    }

    /// Trigger rebase if epoch over
    ///
    /// @return uint256
    function rebase()
        public
        returns (uint256)
    {
        uint256 bounty;
        if (epoch.end <= block.timestamp) {
            sSWIX.rebase(epoch.distribute, epoch.number);

            epoch.end = epoch.end.add(epoch.length);
            epoch.number++;

            if (address(distributor) != address(0)) {
                distributor.distribute();
                // Will mint SWIX for this contract if there exists a bounty
                bounty = distributor.retrieveBounty();
            }
            uint256 balance = SWIX.balanceOf(address(this));
            uint256 staked = sSWIX.circulatingSupply();
            if (balance <= staked.add(bounty)) {
                epoch.distribute = 0;
            } else {
                epoch.distribute = balance.sub(staked).sub(bounty);
            }
        }
        return bounty;
    }


    /* =====================================================
                        GOVERNOR FUNCTIONS
    ===================================================== */

    /// Sets the contract address for LP staking
    ///
    /// @param newDistributor address
    function setDistributor(address newDistributor)
        external
        onlyGovernor
    {
        distributor = IDistributor(newDistributor);
        emit DistributorSet(newDistributor);
    }

    /// Set warmup period for new stakers
    ///
    /// @param setWarmupPeriod uint
    function setWarmupLength(uint256 setWarmupPeriod)
        external
        onlyGovernor
    {
        warmupPeriod = setWarmupPeriod;
        emit WarmupSet(setWarmupPeriod);
    }


    /* =====================================================
                        VIEW FUNCTIONS
    ===================================================== */

    /// Returns the sSWIX index, which tracks rebase growth
    ///
    /// @return uint
    function index()
        public
        view
        returns (uint256)
    {
        return sSWIX.index();
    }

    /// Total supply in warmup
    function supplyInWarmup()
        public
        view
        returns (uint256)
    {
        return sSWIX.balanceForGons(gonsInWarmup);
    }

    /// Seconds until the next epoch begins
    function secondsToNextEpoch()
        external
        view
        returns (uint256)
    {
        return epoch.end.sub(block.timestamp);
    }


    /* =====================================================
                      INTERNAL FUNCTIONS
    ===================================================== */

    /// Send staker their amount as sSWIX or gSWIX
    ///
    /// @param receiver address
    /// @param amount uint
    function _send(
        address receiver,
        uint256 amount
    )
        internal
        returns (uint256)
    {
        // send as sSWIX (equal unit as SWIX)
        sSWIX.safeTransfer(receiver, amount);
        return amount;
    }

    
    /* =====================================================
                            EVENTS
    ===================================================== */

    event DistributorSet(address distributor);
    event WarmupSet(uint256 warmup);
}
