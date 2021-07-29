// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {IERC20} from '../../../dependencies/openzeppelin/contracts/IERC20.sol';
import {SafeMath} from '../../../dependencies/openzeppelin/contracts/SafeMath.sol';
import {SafeERC20} from '../../../dependencies/openzeppelin/contracts/SafeERC20.sol';
import {IAToken} from '../../../interfaces/IAToken.sol';
import {Helpers} from '../helpers/Helpers.sol';
import {ValidationLogic} from './ValidationLogic.sol';
import {ReserveLogic} from './ReserveLogic.sol';
import {DataTypes} from './../types/DataTypes.sol';

import {IStableDebtToken} from '../../../interfaces/IStableDebtToken.sol';
import {IVariableDebtToken} from '../../../interfaces/IVariableDebtToken.sol';

import {UserConfiguration} from './../configuration/UserConfiguration.sol';

import {WadRayMath} from '../math/WadRayMath.sol';

library LendingPoolOtherLogic {
  using ReserveLogic for DataTypes.ReserveCache;
  using ReserveLogic for DataTypes.ReserveData;
  using UserConfiguration for DataTypes.UserConfigurationMap;
  using SafeMath for uint256;
  using SafeERC20 for IERC20;
  using WadRayMath for uint256;

  /**
   * @dev Emitted on setUserUseReserveAsCollateral()
   * @param reserve The address of the underlying asset of the reserve
   * @param user The address of the user enabling the usage as collateral
   **/
  event ReserveUsedAsCollateralEnabled(address indexed reserve, address indexed user);

  /**
   * @dev Emitted on setUserUseReserveAsCollateral()
   * @param reserve The address of the underlying asset of the reserve
   * @param user The address of the user enabling the usage as collateral
   **/
  event ReserveUsedAsCollateralDisabled(address indexed reserve, address indexed user);

  /**
   * @dev Emitted on rebalanceStableBorrowRate()
   * @param reserve The address of the underlying asset of the reserve
   * @param user The address of the user for which the rebalance has been executed
   **/
  event RebalanceStableBorrowRate(address indexed reserve, address indexed user);

  /**
   * @dev Emitted on swapBorrowRateMode()
   * @param reserve The address of the underlying asset of the reserve
   * @param user The address of the user swapping his rate mode
   * @param rateMode The rate mode that the user wants to swap to
   **/
  event Swap(address indexed reserve, address indexed user, uint256 rateMode);

  function rebalanceStableBorrowRate(
    DataTypes.ReserveData storage reserve,
    address asset,
    address user
  ) public {
    DataTypes.ReserveCache memory reserveCache = reserve.cache();

    IERC20 stableDebtToken = IERC20(reserveCache.stableDebtTokenAddress);
    IERC20 variableDebtToken = IERC20(reserveCache.variableDebtTokenAddress);
    uint256 stableDebt = IERC20(stableDebtToken).balanceOf(user);

    ValidationLogic.validateRebalanceStableBorrowRate(
      reserve,
      reserveCache,
      asset,
      stableDebtToken,
      variableDebtToken,
      reserveCache.aTokenAddress
    );

    reserve.updateState(reserveCache);

    IStableDebtToken(address(stableDebtToken)).burn(user, stableDebt);
    IStableDebtToken(address(stableDebtToken)).mint(
      user,
      user,
      stableDebt,
      reserve.currentStableBorrowRate
    );

    reserveCache.refreshDebt(stableDebt, stableDebt, 0, 0);

    reserve.updateInterestRates(reserveCache, asset, 0, 0);

    emit RebalanceStableBorrowRate(asset, user);
  }

  function swapBorrowRateMode(
    DataTypes.ReserveData storage reserve,
    DataTypes.UserConfigurationMap storage userConfig,
    address asset,
    uint256 rateMode
  ) public {
    DataTypes.ReserveCache memory reserveCache = reserve.cache();

    (uint256 stableDebt, uint256 variableDebt) = Helpers.getUserCurrentDebt(msg.sender, reserve);

    DataTypes.InterestRateMode interestRateMode = DataTypes.InterestRateMode(rateMode);

    ValidationLogic.validateSwapRateMode(
      reserve,
      reserveCache,
      userConfig,
      stableDebt,
      variableDebt,
      interestRateMode
    );

    reserve.updateState(reserveCache);

    if (interestRateMode == DataTypes.InterestRateMode.STABLE) {
      IStableDebtToken(reserveCache.stableDebtTokenAddress).burn(msg.sender, stableDebt);
      IVariableDebtToken(reserveCache.variableDebtTokenAddress).mint(
        msg.sender,
        msg.sender,
        stableDebt,
        reserveCache.nextVariableBorrowIndex
      );
      reserveCache.refreshDebt(0, stableDebt, stableDebt, 0);
    } else {
      IVariableDebtToken(reserveCache.variableDebtTokenAddress).burn(
        msg.sender,
        variableDebt,
        reserveCache.nextVariableBorrowIndex
      );
      IStableDebtToken(reserveCache.stableDebtTokenAddress).mint(
        msg.sender,
        msg.sender,
        variableDebt,
        reserve.currentStableBorrowRate
      );
      reserveCache.refreshDebt(variableDebt, 0, 0, variableDebt);
    }

    reserve.updateInterestRates(reserveCache, asset, 0, 0);

    emit Swap(asset, msg.sender, rateMode);
  }

  function setUserUseReserveAsCollateral(
    mapping(address => DataTypes.ReserveData) storage reserves,
    DataTypes.UserConfigurationMap storage userConfig,
    address asset,
    bool useAsCollateral,
    mapping(uint256 => address) storage reservesList,
    uint256 reservesCount,
    address priceOracle
  ) public {
    DataTypes.ReserveData storage reserve = reserves[asset];
    DataTypes.ReserveCache memory reserveCache = reserve.cache();

    uint256 userBalance = IERC20(reserveCache.aTokenAddress).balanceOf(msg.sender);

    ValidationLogic.validateSetUseReserveAsCollateral(reserveCache, userBalance);

    userConfig.setUsingAsCollateral(reserve.id, useAsCollateral);

    if (useAsCollateral) {
      emit ReserveUsedAsCollateralEnabled(asset, msg.sender);
    } else {
      ValidationLogic.validateHFAndLtv(
        asset,
        msg.sender,
        reserves,
        userConfig,
        reservesList,
        reservesCount,
        priceOracle
      );

      emit ReserveUsedAsCollateralDisabled(asset, msg.sender);
    }
  }
}