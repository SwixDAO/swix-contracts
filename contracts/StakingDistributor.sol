// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.7.5;

import "./libraries/SafeERC20.sol";
import "./libraries/SafeMath.sol";

import "./interfaces/IERC20.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/IDistributor.sol";

import "./types/SwixAccessControlled.sol";

contract Distributor is
    IDistributor,
    SwixAccessControlled
{
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* =====================================================
                             STRUCTS
    ===================================================== */

    struct Info {
        // in ten-thousandths ( 5000 = 0.5% )
        uint256 rate;
        address recipient;
    }

    struct Adjust {
        bool add;
        uint256 rate;
        uint256 target;
    }


    /* =====================================================
                            CONSTANTS
     ===================================================== */

    uint256 private constant RATE_DENOMINATOR = 1_000_000;


    /* =====================================================
                            IMMUTABLES
    ===================================================== */

    /// SwixToken Contract
    IERC20 public immutable SWIX;
    /// Swix Treasury Contract
    ITreasury public immutable TREASURY;
    /// SwixStaking Contract
    address public immutable STAKING;


    /* =====================================================
                        STATE VARIABLES
    ===================================================== */

    mapping(uint256 => Adjust) public adjustments;
    uint256 public override bounty;
    Info[] public info;
    

    /* =====================================================
                            CONSTRUCTOR
     ===================================================== */

    constructor(
        address setTreasury,
        address setSwix,
        address setStaking,
        ISwixAuthority setAuthority
    )
        SwixAccessControlled(setAuthority)
    {
        require(setTreasury != address(0), "Zero address: Treasury");
        require(setSwix != address(0), "Zero address: SWIX");
        require(setStaking != address(0), "Zero address: Staking");

        TREASURY = ITreasury(setTreasury);
        SWIX = IERC20(setSwix);
        STAKING = setStaking;
    }


    /* =====================================================
                        STAKING FUNCTIONS
     ===================================================== */

    /// Send epoch reward to staking contract
    function distribute()
        external
        override
    {
        require(msg.sender == STAKING, "Only staking");

        // distribute rewards to each recipient
        for (uint256 i = 0; i < info.length; i++) {
            if (info[i].rate > 0) {
                // mint and send tokens
                TREASURY.mint(info[i].recipient, nextRewardAt(info[i].rate));
                // check for adjustment
                adjust(i);
            }
        }
    }

    function retrieveBounty()
        external
        override
        returns (uint256)
    {
        require(msg.sender == STAKING, "Only staking");
        // If the distributor bounty is > 0, mint it for the staking contract.
        if (bounty > 0) {
            TREASURY.mint(address(STAKING), bounty);
        }

        return bounty;
    }


    /* =====================================================
                        GOVERNOR FUNCTIONS
     ===================================================== */

    /// Set bounty to incentivize keepers
    ///
    /// @param newBounty uint256
    function setBounty(uint256 newBounty)
        external
        override
        onlyGovernor
    {
        require(newBounty <= 2e9, "Too much");
        bounty = newBounty;
    }

    /// Adds recipient for distributions
    ///
    /// @param newRecipient address
    /// @param rewardRate uint
    function addRecipient(address newRecipient, uint256 rewardRate)
        external
        override
        onlyGovernor
    {
        require(newRecipient != address(0), "Zero address: Recipient");
        require(
            rewardRate <= RATE_DENOMINATOR,
            "Rate cannot exceed denominator"
        );
        info.push(Info({recipient: newRecipient, rate: rewardRate}));
    }


    /* =====================================================
                  GOVERNOR & GUARDIAN FUNCTIONS
     ===================================================== */

    /// Removes recipient for distributions
    ///
    /// @param recipientIndex uint
    function removeRecipient(uint256 recipientIndex)
        external
        override
    {
        require(
            msg.sender == authority.governor() || msg.sender == authority.guardian(),
            "Caller is not governor or guardian"
        );

        require(
            info[recipientIndex].recipient != address(0),
            "Recipient does not exist"
        );

        info[recipientIndex].recipient = address(0);
        info[recipientIndex].rate = 0;
    }

    /// Set adjustment info for a collector's reward rate
    ///
    /// @param recipientIndex   uint
    /// @param isAdd            bool
    /// @param newRate          uint
    /// @param newTarget        uint
    function setAdjustment(
        uint256 recipientIndex,
        bool isAdd,
        uint256 newRate,
        uint256 newTarget
    )
        external
        override
    {
        require(
            msg.sender == authority.governor() ||
                msg.sender == authority.guardian(),
            "Caller is not governor or guardian"
        );

        require(
            info[recipientIndex].recipient != address(0),
            "Recipient does not exist"
        );

        if (msg.sender == authority.guardian()) {
            require(
                newRate <= info[recipientIndex].rate.mul(25).div(1000),
                "Limiter: cannot adjust by >2.5%"
            );
        }

        if (!isAdd) {
            require(
                newRate <= info[recipientIndex].rate,
                "Cannot decrease rate by more than it already is"
            );
        }

        adjustments[recipientIndex] = Adjust({
            add: isAdd,
            rate: newRate,
            target: newTarget
        });
    }


    /* =====================================================
                            VIEW FUNCTIONS
     ===================================================== */

    /// View function for next reward at given rate
    ///
    /// @param rate uint
    ///
    /// @return uint
    function nextRewardAt(uint256 rate)
        public
        view
        override
        returns (uint256)
    {
        return SWIX.totalSupply().mul(rate).div(RATE_DENOMINATOR);
    }

    /// View function for next reward for specified address
    ///
    /// @param recipient address
    ///
    /// @return uint
    function nextRewardFor(address recipient)
        public
        view
        override
        returns (uint256)
    {
        uint256 reward;
        for (uint256 i = 0; i < info.length; i++) {
            if (info[i].recipient == recipient) {
                reward = reward.add(nextRewardAt(info[i].rate));
            }
        }
        return reward;
    }


    /* =====================================================
                        INTERNAL FUNCTIONS
     ===================================================== */

    /// Increment reward rate for collector
    function adjust(uint256 adjustmentIndex)
        internal
    {
        Adjust memory adjustment = adjustments[adjustmentIndex];
        if (adjustment.rate != 0) {
            // if rate should increase
            if (adjustment.add) {
                // raise rate
                info[adjustmentIndex].rate = info[adjustmentIndex].rate.add(adjustment.rate); 

                // if target met
                if (info[adjustmentIndex].rate >= adjustment.target) {
                    // turn off adjustment
                    adjustments[adjustmentIndex].rate = 0;
                    // set to target
                    info[adjustmentIndex].rate = adjustment.target; 
                }
            }
            else {
                // if rate should decrease protect from underflow
                if (info[adjustmentIndex].rate > adjustment.rate) {
                    // lower rate
                    info[adjustmentIndex].rate = info[adjustmentIndex].rate.sub(adjustment.rate); 
                }
                else {
                    info[adjustmentIndex].rate = 0;
                }

                // if target met
                if (info[adjustmentIndex].rate <= adjustment.target) {
                    // turn off adjustment
                    adjustments[adjustmentIndex].rate = 0;
                    // set to target
                    info[adjustmentIndex].rate = adjustment.target;
                }
            }
        }
    }
}
