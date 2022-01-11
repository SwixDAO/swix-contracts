// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.7.5;

import "./libraries/SafeMath.sol";
import "./libraries/SafeERC20.sol";

import "./interfaces/IERC20.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/IStaking.sol";
import "./interfaces/IsSWIX.sol";
import "./interfaces/ITeller.sol";

import "./types/SwixAccessControlled.sol";

contract BondTeller is
    ITeller,
    SwixAccessControlled
{
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IsSWIX;


    /* =====================================================
                            STRUCTS
    ===================================================== */

    /// Info for bond holder
    struct Bond {
        // token used to pay for bond
        address bondToken;
        // amount of bondToken token paid for bond
        uint256 bondTokenPaid;
        // sSWIX remaining to be paid. agnostic balance
        uint256 payout;
        // Block when bond is vested
        uint256 vested;
        // time bond was created
        uint256 created;
        // time bond was redeemed
        uint256 redeemed;
    }


    /* =====================================================
                        CONSTANTS
    ===================================================== */

    uint256 constant ONE_HUNDERD_PERCENT = 10000;
    uint256 constant DECIMALS = 10**18;


    /* =====================================================
                        IMMUTABLES
    ===================================================== */

    /// contract where users deposit bonds
    address public immutable DEPOSITORY;
    /// contract to stake payout
    IStaking public immutable STAKING;
    /// Swix DAO Treasury
    ITreasury public immutable TREASURY;
    /// Swix ERC20 Token     
    IERC20 public immutable SWIX;
    /// payment token
    IsSWIX public immutable SSWIX; 


    /* =====================================================
                      STATE VARIABLES
    ===================================================== */           

    /// user data
    mapping(address => Bond[]) public userBonds;       
    /// user bond indexes
    mapping(address => uint256[]) public userBondsIndexes;    

    /// front end operator rewards
    mapping(address => uint256) public frontEndRewards;            
    /// percentage of bond payout given to the pront end operator
    uint256 public frontEndReward;


    /* =====================================================
                          MODIFIERS
    ===================================================== */

    modifier onlyDepository() {
        require(msg.sender == DEPOSITORY, "Only depository");
        _;
    }                       


    /* =====================================================
                        CONSTRUCTOR
    ===================================================== */

    constructor(
        address setDepository,
        address setStaking,
        address setTreasury,
        address setSwix,
        address setSSwix,
        ISwixAuthority setAuthority
    )
        SwixAccessControlled(setAuthority)
    {
        require(setDepository != address(0), "Zero address: Depository");
        require(setStaking != address(0), "Zero address: Staking");
        require(setTreasury != address(0), "Zero address: Treasury");
        require(setSwix != address(0), "Zero address: SWIX");
        require(setSSwix != address(0), "Zero address: sSWIX");
        
        DEPOSITORY = setDepository;
        STAKING = IStaking(setStaking);
        TREASURY = ITreasury(setTreasury);
        SWIX = IERC20(setSwix);
        SSWIX = IsSWIX(setSSwix);
    }

        
    /* =====================================================
                        USER FUNCTIONS
    ===================================================== */
    
    /// Redeems all redeemable bonds
    ///
    /// @param bonder address
    ///
    /// @return uint256
    function redeemAll(address bonder)
        external
        override
        returns (uint256)
    {
        updateUserBondsIndexes(bonder);
        return redeem(bonder, userBondsIndexes[bonder]);
    }

    /// Redeem bond for user
    ///
    /// @param bonder address
    /// @param userBondIndexes memory uint256[]
    ///
    /// @return uint256
    function redeem(
        address bonder,
        uint256[] memory userBondIndexes
    )
        public
        override
        returns (uint256)
    {
        uint256 dues;
        for (uint256 i = 0; i < userBondIndexes.length; i++) {
            Bond memory info = userBonds[bonder][userBondIndexes[i]];

            if (pendingFor(bonder, userBondIndexes[i]) != 0) {
                // mark as redeemed
                userBonds[bonder][userBondIndexes[i]].redeemed = block.timestamp;

                dues = dues.add(info.payout);
            }
        }

        dues = dues.mul(index()).div(10**DECIMALS);

        emit Redeemed(bonder, dues);
        SSWIX.safeTransfer(bonder, dues);
        return dues;
    }

    /// Pay reward to front end operator
    function getFrontEndReward()
        external
        override
    {
        uint256 reward = frontEndRewards[msg.sender];
        frontEndRewards[msg.sender] = 0;
        SWIX.safeTransfer(msg.sender, reward);
    }


    /* =====================================================
                      DEPOSITORY FUNCTIONS
    ===================================================== */

    /// Add new bond payout to user data
    ///
    /// @param bonder           address
    /// @param bondToken        address
    /// @param bondTokenPaid    uint256
    /// @param payout           uint256
    /// @param expires          uint256
    /// @param frontEndOperator address
    ///
    /// @return userBondIndex uint256
    function newBond(
        address bonder,
        address bondToken,
        uint256 bondTokenPaid,
        uint256 payout,
        uint256 expires,
        address frontEndOperator
    )
        external
        override
        onlyDepository
        returns (uint256 userBondIndex)
    {
        uint256 reward = payout.mul(frontEndReward).div(ONE_HUNDERD_PERCENT);
        TREASURY.mint(address(this), payout.add(reward));

        SWIX.approve(address(STAKING), payout);
        STAKING.stake(address(this), payout, true);

        // front end operator reward
        frontEndRewards[frontEndOperator] = frontEndRewards[frontEndOperator].add(reward);

        userBondIndex = userBonds[bonder].length;

        // store bond & stake payout
        userBonds[bonder].push(
            Bond({
                bondToken: bondToken,
                bondTokenPaid: bondTokenPaid,
                payout: payout.mul(10**DECIMALS).div(index()),
                vested: expires,
                created: block.timestamp,
                redeemed: 0
            })
        );
    }


    /* =====================================================
                        POLICY FUNCTIONS
    ===================================================== */

    /// Set reward for front end operator (4 decimals. 100 = 1%)
    function setFrontEndReward(uint256 reward)
        external
        override
        onlyPolicy
    {
        frontEndReward = reward;
    }


    /* =====================================================
                        VIEW FUNCTIONS
    ===================================================== */

    /// Updates the user's userBondIndex to only live bonds
    ///
    /// @param bonder address
    function updateUserBondsIndexes(address bonder)
        public
        override
    {
        Bond[] memory info = userBonds[bonder];
        delete userBondsIndexes[bonder];
        for (uint256 i = 0; i < info.length; i++) {
            if (info[i].redeemed == 0) {
                userBondsIndexes[bonder].push(i);
            }
        }
    }

    // PAYOUT

    /// Calculate amount of SWIX available for claim for single bond
    ///
    /// @param bonder address
    /// @param userBondIndex uint256
    ///
    /// @return uint256
    function pendingFor(
        address bonder,
        uint256 userBondIndex
    )
        public
        view
        override
        returns (uint256)
    {
        if (userBonds[bonder][userBondIndex].redeemed == 0 && userBonds[bonder][userBondIndex].vested <= block.number) {
            return userBonds[bonder][userBondIndex].payout;
        }
        return 0;
    }

    /// Calculate amount of SWIX available for claim for array of bonds
    ///
    /// @param bonder address
    /// @param userBondIndexes uint256[]
    ///
    /// @return pending uint256
    function pendingForIndexes(
        address bonder,
        uint256[] memory userBondIndexes
    )
        public
        view
        override
        returns (uint256 pending)
    {
        for (uint256 i = 0; i < userBondIndexes.length; i++) {
            pending = pending.add(pendingFor(bonder, i));
        }
        pending = pending.mul(index()).div(10**DECIMALS);
    }

    /// Total pending on all bonds for bonder
    ///
    /// @param bonder address
    ///
    /// @return pending uint256
    function totalPendingFor(address bonder)
        public
        view
        override
        returns (uint256 pending)
    {
        Bond[] memory info = userBonds[bonder];
        for (uint256 i = 0; i < info.length; i++) {
            pending = pending.add(pendingFor(bonder, i));
        }
        pending = pending.mul(index()).div(10**DECIMALS);
    }

    // VESTING
    
    /// Calculate how far into vesting a depositor is
    ///
    /// @param bonder address
    /// @param userBondIndex uint256
    ///
    /// @return percentVested uint256
    function percentVestedFor(
        address bonder,
        uint256 userBondIndex
    )
        public
        view
        override
        returns (uint256 percentVested)
    {
        Bond memory bond = userBonds[bonder][userBondIndex];

        uint256 timeSince = block.timestamp.sub(bond.created);
        uint256 term = bond.vested.sub(bond.created);

        percentVested = timeSince.mul(1e9).div(term);
    }

    function index() public view returns (uint256) {
        return SSWIX.index();
    }


    /* =====================================================
                            EVENTS
    ===================================================== */

    event BondCreated(address indexed bonder, uint256 payout, uint256 expires);
    event Redeemed(address indexed bonder, uint256 payout);
}
