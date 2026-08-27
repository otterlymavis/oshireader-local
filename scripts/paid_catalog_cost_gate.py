#!/usr/bin/env python3
"""Calculate the minimum gross price for OshiReader hosted service acceptance."""

from __future__ import annotations

import argparse
import json
from decimal import Decimal, InvalidOperation, ROUND_UP


DAYS_PER_MONTH = Decimal("365.25") / Decimal("12")
SOAK_DAYS = Decimal("7")
OPERATIONAL_RESERVE = Decimal("1.20")
TARGET_COST_COVERAGE = Decimal("2")
# Flat 30% Apple commission. Deliberately ignores the 15% Small Business /
# post-year-1 subscription rate: this computes a *price floor*, so assuming the
# worse (higher) commission keeps the floor conservative rather than a bug.
APPLE_NET_SHARE = Decimal("0.70")


def money(value: Decimal) -> str:
    return str(value.quantize(Decimal("0.01"), rounding=ROUND_UP))


def nonnegative_decimal(raw: str) -> Decimal:
    try:
        value = Decimal(raw)
    except (InvalidOperation, ValueError):
        raise argparse.ArgumentTypeError(f"{raw!r} is not a number")
    if value < 0:
        raise argparse.ArgumentTypeError("costs and prices must be nonnegative")
    return value


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Extrapolate the seven-day, ten-term hosted soak into a launch price gate."
    )
    for category in ("compute", "database", "egress", "proxy", "apns", "diagnostics"):
        parser.add_argument(f"--{category}", type=nonnegative_decimal, default=Decimal("0"))
    parser.add_argument(
        "--monthly-price",
        type=nonnegative_decimal,
        help="Optional proposed Apple monthly price to evaluate against the gate.",
    )
    args = parser.parse_args()

    categories = {
        name: getattr(args, name)
        for name in ("compute", "database", "egress", "proxy", "apns", "diagnostics")
    }
    seven_day_cost = sum(categories.values(), Decimal("0"))
    if seven_day_cost <= 0:
        # Every category defaulted to 0 — the caller forgot the cost flags.
        # Without a real soak cost the floor is 0 and any price "passes",
        # so fail loudly instead of green-lighting silently.
        parser.error(
            "no soak costs given: pass the measured --compute/--database/--egress/"
            "--proxy/--apns/--diagnostics figures (at least one must be > 0)"
        )
    monthly_cost = seven_day_cost * DAYS_PER_MONTH / SOAK_DAYS
    reserved_monthly_cost = monthly_cost * OPERATIONAL_RESERVE
    minimum_gross_monthly = reserved_monthly_cost * TARGET_COST_COVERAGE / APPLE_NET_SHARE

    proposed = args.monthly_price
    annual_monthly_basis = (
        proposed
        if proposed is not None and proposed >= minimum_gross_monthly
        else minimum_gross_monthly
    )
    output = {
        "currency": "EUR",
        "soak_days": 7,
        "active_terms": 10,
        "seven_day_costs": {name: money(value) for name, value in categories.items()},
        "seven_day_total": money(seven_day_cost),
        "extrapolated_monthly_cost": money(monthly_cost),
        "reserved_monthly_cost": money(reserved_monthly_cost),
        "minimum_gross_monthly_price": money(minimum_gross_monthly),
        "suggested_annual_price_at_ten_months": money(annual_monthly_basis * Decimal("10")),
        "assumptions": {
            "operational_reserve": "20%",
            "target_cost_coverage": "2x",
            "apple_commission": "30%",
        },
    }
    if proposed is not None:
        output["proposed_monthly_price"] = money(proposed)
        output["price_gate_passed"] = proposed >= minimum_gross_monthly

    print(json.dumps(output, indent=2, sort_keys=True))
    return 0 if proposed is None or proposed >= minimum_gross_monthly else 2


if __name__ == "__main__":
    raise SystemExit(main())
