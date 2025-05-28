## Contracts that turn PriceFeeds into V3 Oracles

This repo contains contracts for exposing data found in PriceFeeds, such as Pyth or ChainLink, into Uni V3 formatted price data, including `slot0`, `observe`, and `observations`.

The first implementation is one for Pyth. Our motivation was to use this as a reliable price feed for Panoptic v1.1 on Unichain, hence the test's choice to fork Unichain values.

## Setup

```bash
# 0. Get foundry: https://book.getfoundry.sh/getting-started/installation
# 1. Install dependencies:
git submodule update --init --recursive
forge install

# 2. Run the tests:
forge test
```
