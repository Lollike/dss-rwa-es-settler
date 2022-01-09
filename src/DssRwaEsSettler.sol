// SPDX-License-Identifier: AGPL-3.0-or-later

/// pot.sol -- Dai Savings Rate

// Copyright (C) 2018 Rain <rainbreak@riseup.net>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity 0.8.10;

interface GemLike {
    function decimals() external view returns (uint);
    function transfer(address,uint) external returns (bool);
    function transferFrom(address,address,uint) external returns (bool);
}

contract DssRwaEsSettler {
    // --- Auth ---
    mapping (address => uint) public wards;
    function rely(address guy) external auth { wards[guy] = 1; }
    function deny(address guy) external auth { wards[guy] = 0; }
    modifier auth {
        require(wards[msg.sender] == 1, "Pot/not-authorized");
        _;
    }

    // --- Data ---
    mapping (address => uint256) public rwaBalance;  // RWA Balances
    mapping (address => uint256) public redeemedStablecoin; //redeemed stablecoin
    int256 public immutable initialArt;
    uint256 public immutable initialInk;
    uint256 public repaidStablecoin;   // Normalized Debt [wad]
    int256 public art;   // Normalized Debt [wad]
    uint256 public duty;  // Collateral-specific, per-second stability fee contribution [ray]
    uint256 public rate;  // Accumulated Rates     [ray]
    uint256 public rho;   // Time of last drip     [unix epoch time]

    uint256 public live;  // Active Flag
    GemLike public rwa; // RWA token
    GemLike public sta; // Stablecoin used for repayment

    

    // --- Init ---
    constructor(int256 _art, uint256 _duty, uint256 _initialInk, GemLike _rwa, GemLike _sta) {
        wards[msg.sender] = 1;
        art = _art;
        initialArt = _art;
        duty = _duty;
        initialInk = _initialInk;
        rate = ONE;
        rho = block.timestamp;
        live = 1;
        rwa = _rwa;
        sta = _sta;
    }

    // --- Math ---
    uint256 constant RAY = 10 ** 27;

    uint256 constant ONE = 10 ** 27;
    function rpow(uint x, uint n, uint base) internal pure returns (uint z) {
        assembly {
            switch x case 0 {switch n case 0 {z := base} default {z := 0}}
            default {
                switch mod(n, 2) case 0 { z := base } default { z := x }
                let half := div(base, 2)  // for rounding.
                for { n := div(n, 2) } n { n := div(n,2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0,0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0,0) }
                    x := div(xxRound, base)
                    if mod(n,2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0,0) }
                        z := div(zxRound, base)
                    }
                }
            }
        }
    }

    function rmul(uint x, uint y) internal pure returns (uint z) {
        z = mul(x, y) / ONE;
    }

    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x);
    }

    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }

    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    function toInt(uint x) internal pure returns (int y) {
        y = int(x);
        require(y >= 0, "int-overflow");
    }

    // --- Administration ---
    function file(bytes32 what, uint256 data) external auth {
        require(live == 1, "RwaEsSettler/not-live");
        require(block.timestamp == rho, "RwaEsSettler/rho-not-updated");
        if (what == "duty") duty = data;
        else revert("RwaEsSettler/file-unrecognized-param");
    }

    function cage() external auth {
        live = 0;
        duty = ONE;
    }

    // --- Stability Fee Accumulation ---
    function drip() external returns (uint tmp) {
        require(block.timestamp >= rho, "RwaEsSettler//invalid-now");
        tmp = rmul(rpow(duty, block.timestamp - rho, ONE), rate);
        uint rate_ = sub(tmp, rate);
        rate = tmp;
        rho = block.timestamp;
    }


    // initial dai amount
    // dairedeemed[]


    // --- Loan Management ---
    function repayStablecoin(uint wad) public {
        sta.transferFrom(msg.sender, address(this), wad);
        repaidStablecoin = repaidStablecoin + wad;
        int256 dart = toInt(wad*RAY/rate);
        art = art + dart;
    }

    // --- RWA Token Redemption ---
    function joinRwa(uint wad) external {
        rwa.transferFrom(msg.sender, address(this), wad);
        rwaBalance[msg.sender] = add(rwaBalance[msg.sender], wad);
    }

    function redeemRwa(uint wad) external {
        
        rwaBalance[msg.sender] = sub(rwaBalance[msg.sender], wad);
        rwa.transfer(msg.sender, wad);
    }

    function exitStablecoin() external {
        uint256 rwaFraction = rwaBalance[msg.sender]/initialInk;
        uint256 stablecoinAmount = rwaFraction*repaidStablecoin - redeemedStablecoin[msg.sender];
        redeemedStablecoin[msg.sender] = redeemedStablecoin[msg.sender]+stablecoinAmount;

        //Pie             = sub(Pie,             wad);
        sta.transfer(msg.sender, stablecoinAmount);
        // vat.move(address(this), msg.sender, mul(chi, wad));
        // move Dai from this contract to msg sender
    }
}


// 10 % of tokens should give me 10 % of repaid stablecoins
// calcualte how many stablecoins I can redeem
// 10 % share of repaid tokens. 15 % has been repaid
// 0.1*0.15 redeemed
// share = joinedRwa/totalInk
// redeemed share = 