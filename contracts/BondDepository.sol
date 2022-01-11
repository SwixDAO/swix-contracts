// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.7.5;
pragma abicoder v2;

import "./libraries/SafeMath.sol";
import "./libraries/FixedPoint.sol";
import "./libraries/Address.sol";
import "./libraries/SafeERC20.sol";

import "./types/SwixAccessControlled.sol";

import "./interfaces/ITreasury.sol";
import "./interfaces/IBondingCalculator.sol";
import "./interfaces/ITeller.sol";
import "./interfaces/IERC20Metadata.sol";

contract SwixBondDepository is SwixAccessControlled {
    using FixedPoint for *;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    /* =====================================================
                            STRUCTS
     ===================================================== */

    /// Info about each type of bond
    struct Bond {
        // token accepted as payment
        IERC20 bondToken;
        // contract to value bondToken
        IBondingCalculator calculator;
        // terms of bond
        Terms terms;
        // total debt from bond
        uint256 totalDebt;
        // last block when debt was decayed
        uint256 lastDecay;
        // capacity remaining
        uint256 capacity;
        // capacity limit is for payout or bondToken
        bool capacityIsPayout;
        // have terms been set
        bool termsSet;
    }

    /// Info for creating new bonds
    struct Terms {
        // scaling variable for price
        uint256 controlVariable;
        // fixed term or fixed expiration
        bool fixedTerm;
        // term in blocks (fixed-term)
        uint256 vestingTerm;
        // block number bond matures (fixed-expiration)
        uint256 expiration;
        // block number bond no longer offered
        uint256 conclusion;
        // vs bondToken value
        uint256 minimumPrice;
        // in thousandths of a %. i.e. 500 = 0.5%
        uint256 maxPayout;
        // 9 decimal debt ratio, max % total supply created as debt
        uint256 maxDebt;
    }

    
    /* =====================================================
                            IMMUTABLES
     ===================================================== */

    /// SWIX ERC20 token
    IERC20 public immutable SWIX;    
    /// Swix Treasury
    ITreasury public immutable TREASURY;


    /* =====================================================
                        STATE VARIABLES
     ===================================================== */

    /// Mapping of all accepted bonds
    mapping(uint256 => Bond) public bonds;
    /// Array of bond IDs
    address[] public IDs;

    /// Handles payments
    ITeller public teller;


    /* =====================================================
                            CONSTRUCTOR
    ===================================================== */

    constructor(
        address setSwix,
        address setTreasury,
        ISwixAuthority setAuthority
    ) 
        SwixAccessControlled(setAuthority)
    {
        require(setSwix != address(0));
        require(setTreasury != address(0));
        
        SWIX = IERC20(setSwix);
        TREASURY = ITreasury(setTreasury);
    }


    /* =====================================================
                        USER FUNCTIONS
    ===================================================== */

    /// Deposit bond
    ///
    /// @param amount           uint
    /// @param maxPrice         uint
    /// @param receiver        address
    /// @param bondId           uint
    /// @param frontEndOperator address
    ///
    /// @return uint
    function deposit(
        uint256 amount,
        uint256 maxPrice,
        address receiver,
        uint256 bondId,
        address frontEndOperator
    )
        external
        returns (uint256, uint256)
    {
        require(receiver != address(0), "Invalid address");

        Bond memory bond = bonds[bondId];

        require(bonds[bondId].termsSet, "Not initialized");
        require(block.number < bond.terms.conclusion, "Bond concluded");

        emit BeforeBond(
            bondId,
            bondPriceInUSD(bondId),
            bondPrice(bondId),
            debtRatio(bondId)
        );

        _decayDebt(bondId);

        require(bond.totalDebt <= bond.terms.maxDebt, "Max debt exceeded");
        // slippage protection
        require(
            maxPrice >= _bondPrice(bondId),
            "Slippage limit: more than max price"
        );

        uint256 value = TREASURY.tokenValue(address(bond.bondToken), amount);
        // payout to bonder is computed
        uint256 payout = payoutFor(value, bondId);

        // ensure there is remaining capacity for bond
        if (bond.capacityIsPayout) {
            // capacity in payout terms
            require(bond.capacity >= payout, "Bond concluded");
            bond.capacity = bond.capacity.sub(payout);
        } else {
            // capacity in bondToken terms
            require(bond.capacity >= amount, "Bond concluded");
            bond.capacity = bond.capacity.sub(amount);
        }

        // must be > 0.01 SWIX ( underflow protection )
        require(payout >= 10000000, "Bond too small");
        // size protection because there is no slippage
        require(payout <= maxPayout(bondId), "Bond too large");

        // send payout to treasury
        bond.bondToken.safeTransfer(address(TREASURY), amount);
        // increase total debt
        bonds[bondId].totalDebt = bond.totalDebt.add(value);

        uint256 expiration = bond.terms.vestingTerm.add(block.number);

        if (!bond.terms.fixedTerm) {
            expiration = bond.terms.expiration;
        }

        // user bond stored with teller
        uint256 index = teller.newBond(
            receiver,
            address(bond.bondToken),
            amount,
            payout,
            expiration,
            frontEndOperator
        );

        emit CreateBond(bondId, amount, payout, expiration);

        return (payout, index);
    }


    /* =====================================================
                        GUARDIAN FUNCTIONS
    ===================================================== */

    /// Creates a new bond type
    ///
    /// @param setBondToken         address
    /// @param setCalculator        address
    /// @param setCapacity          uint
    /// @param setCapacityIsPayout  bool
    function addBond(
        address setBondToken,
        address setCalculator,
        uint256 setCapacity,
        bool setCapacityIsPayout
    )
        external
        onlyGuardian
        returns (uint256 bondId)
    {
        Terms memory terms = Terms({
            controlVariable: 0,
            fixedTerm: false,
            vestingTerm: 0,
            expiration: 0,
            conclusion: 0,
            minimumPrice: 0,
            maxPayout: 0,
            maxDebt: 0
        });

        bonds[IDs.length] = Bond({
            bondToken: IERC20(setBondToken),
            calculator: IBondingCalculator(setCalculator),
            terms: terms,
            termsSet: false,
            totalDebt: 0,
            lastDecay: block.number,
            capacity: setCapacity,
            capacityIsPayout: setCapacityIsPayout
        });

        bondId = IDs.length;
        IDs.push(setBondToken);
    }

    /// Set terms for a new bond
    ///
    /// @param bondId           uint256
    /// @param initialDebt      uint256
    /// @param terms            Terms
    function setTerms(
        uint256 bondId,
        uint256 initialDebt,
        Terms calldata terms
    )
        external
        onlyGuardian
    {   
        require(!bonds[bondId].termsSet, "TERMS_SET");

        bonds[bondId].terms = terms;
        bonds[bondId].totalDebt = initialDebt;
        bonds[bondId].termsSet = true;
    }

    /// Disable existing bond
    ///
    /// @param bondId uint
    function deprecateBond(uint256 bondId)
        external
        onlyGuardian
    {
        bonds[bondId].capacity = 0;
    }


    /* =====================================================
                        GOVERNOR FUNCTIONS
    ===================================================== */

    /// Set teller contract
    ///
    /// @param newTeller address
    function setTeller(address newTeller)
        external
        onlyGovernor
    {
        require(address(teller) == address(0));
        require(newTeller != address(0));

        teller = ITeller(newTeller);
    }
    

    /* =====================================================
                        VIEW FUNCTIONS
    ===================================================== */

    // BOND TYPE INFO
    
    /// Returns data about a bond type
    ///
    /// @param bondId uint
    ///
    /// @return address
    /// @return address
    /// @return uint256
    /// @return uint256
    function bondInfo(uint256 bondId)
        external
        view
        returns (address, address, uint256, uint256)
    {   
        return(
            address(bonds[bondId].bondToken),
            address(bonds[bondId].calculator),
            bonds[bondId].totalDebt,
            bonds[bondId].lastDecay
        );
    }

    /// Returns terms for a bond type
    ///
    /// @param bondId uint256
    ///
    /// @return uint256
    /// @return uint256
    /// @return uint256
    /// @return uint256
    /// @return uint256
    function bondTerms(uint256 bondId)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256)
    {
        return(
            bonds[bondId].terms.controlVariable,
            bonds[bondId].terms.vestingTerm,
            bonds[bondId].terms.minimumPrice,
            bonds[bondId].terms.maxPayout,
            bonds[bondId].terms.maxDebt
        );
    }

    // PAYOUT

    /// Determine maximum bond size
    ///
    /// @param bondId uint
    ///
    /// @return uint
    function maxPayout(uint256 bondId)
        public
        view
        returns (uint256)
    {
        return
            TREASURY.baseSupply()
                .mul(bonds[bondId].terms.maxPayout)
                .div(100000);
    }

    /// Payout due for amount of treasury value
    ///
    /// @param value    uint
    /// @param bondId   uint
    ///
    /// @return uint
    function payoutFor(uint256 value, uint256 bondId)
        public
        view
        returns (uint256)
    {
        return
            FixedPoint.fraction(value, bondPrice(bondId))
                .decode112with18()
                .div(1e16);
    }

    /// Payout due for amount of token
    ///
    /// @param amount uint
    /// @param bondId uint
    function payoutForAmount(uint256 amount, uint256 bondId)
        public
        view
        returns (uint256)
    {
        address bondToken = address(bonds[bondId].bondToken);
        return payoutFor(TREASURY.tokenValue(bondToken, amount), bondId);
    }

    // BOND PRICE
    
    /// Calculate current bond premium
    ///
    /// @param bondId uint
    ///
    /// @return price uint
    function bondPrice(uint256 bondId)
        public
        view
        returns (uint256 price)
    {
        price = bonds[bondId].terms.controlVariable
            .mul(debtRatio(bondId))
            .add(1000000000)
            .div(1e7);

        if (price < bonds[bondId].terms.minimumPrice) {
            price = bonds[bondId].terms.minimumPrice;
        }
    }

    /// Converts bond price to DAI value
    ///
    /// @param bondId uint
    ///
    /// @return price uint
    function bondPriceInUSD(uint256 bondId)
        public
        view
        returns (uint256 price)
    {
        Bond memory bond = bonds[bondId];
        if (address(bond.calculator) != address(0)) {
            price = bondPrice(bondId)
                .mul(bond.calculator.markdown(address(bond.bondToken)))
                .div(100);
        } else {
            price = bondPrice(bondId)
                .mul(10**IERC20Metadata(address(bond.bondToken)).decimals())
                .div(100);
        }
    }

    // DEBT

    /// Calculate current ratio of debt to SWIX supply
    ///
    /// @param bondId uint
    ///
    /// @return currentDebtRatio uint
    function debtRatio(uint256 bondId)
        public
        view
        returns (uint256 currentDebtRatio)
    {
        currentDebtRatio = FixedPoint
            .fraction(currentDebt(bondId).mul(1e9), TREASURY.baseSupply())
            .decode112with18()
            .div(1e18);
    }

    /// Debt ratio in same terms for reserve or liquidity bonds
    ///
    /// @return uint
    function standardizedDebtRatio(uint256 bondId)
        public
        view
        returns (uint256)
    {
        Bond memory bond = bonds[bondId];

        if (address(bond.calculator) != address(0)) {
            return
                debtRatio(bondId)
                    .mul(bond.calculator.markdown(address(bond.bondToken)))
                    .div(1e9);
        } else {
            return debtRatio(bondId);
        }
    }

    /// Calculate debt factoring in decay
    ///
    /// @param bondId uint
    ///
    /// @return uint
    function currentDebt(uint256 bondId)
        public
        view
        returns (uint256)
    {
        return bonds[bondId].totalDebt.sub(debtDecay(bondId));
    }

    /// Amount to decay total debt by
    ///
    /// @param bondId uint
    ///
    /// @return decayAmount uint
    function debtDecay(uint256 bondId)
        public
        view
        returns (uint256 decayAmount)
    {
        Bond memory bond = bonds[bondId];

        uint256 blocksSinceLast = block.number.sub(bond.lastDecay);

        decayAmount = bond.totalDebt.mul(blocksSinceLast).div(
            bond.terms.vestingTerm
        );

        if (decayAmount > bond.totalDebt) {
            decayAmount = bond.totalDebt;
        }
    }


    /* =====================================================
                        INTERNAL FUNCTIONS
    ===================================================== */

    /// Calculate current bond price and remove floor if above
    ///
    /// @param bondId uint
    ///
    /// @return price uint
    function _bondPrice(uint256 bondId)
        internal
        returns (uint256 price)
    {
        Bond memory info = bonds[bondId];
        price = info
            .terms
            .controlVariable
            .mul(debtRatio(bondId))
            .add(1000000000)
            .div(1e7);
        if (price < info.terms.minimumPrice) {
            price = info.terms.minimumPrice;
        } else if (info.terms.minimumPrice != 0) {
            bonds[bondId].terms.minimumPrice = 0;
        }
    }
    
    /// Reduce total debt
    ///
    /// @param bondId uint
    function _decayDebt(uint256 bondId)
        internal
    {
        bonds[bondId].totalDebt = bonds[bondId].totalDebt.sub(debtDecay(bondId));
        bonds[bondId].lastDecay = block.number;
    }


    /* =====================================================
                            EVENTS
    ===================================================== */

    event BeforeBond(
        uint256 index,
        uint256 price,
        uint256 internalPrice,
        uint256 debtRatio
    );
    event CreateBond(
        uint256 index,
        uint256 amount,
        uint256 payout,
        uint256 expires
    );
    event AfterBond(
        uint256 index,
        uint256 price,
        uint256 internalPrice,
        uint256 debtRatio
    );
}
