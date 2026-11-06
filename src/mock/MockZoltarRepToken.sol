// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

import { IZoltarRepToken } from "../interfaces/IZoltarRepToken.sol";
import { MockERC20 } from "./MockERC20.sol";

/// @notice A Zoltar child REP token: a MockERC20 carrying Zoltar's repNumber and its "Augur Reputation <n>" /
///         "REP<n>" naming. The genesis stays a plain MockERC20, like REPv2 (no repNumber).
contract MockZoltarRepToken is MockERC20, IZoltarRepToken {
    uint256 public repNumber;

    constructor(uint256 repNumber_)
        MockERC20(
            string.concat("Augur Reputation ", Strings.toString(repNumber_)),
            string.concat("REP", Strings.toString(repNumber_))
        )
    {
        repNumber = repNumber_;
    }
}
