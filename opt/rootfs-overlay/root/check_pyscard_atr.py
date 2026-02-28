#!/usr/bin/env python3

import sys

from smartcard.CardRequest import CardRequest
from smartcard.CardType import AnyCardType
from smartcard.Exceptions import CardRequestTimeoutException, NoCardException
from smartcard.System import readers
from smartcard.util import toHexString


def main() -> int:
    timeout = int(sys.argv[1]) if len(sys.argv) > 1 else 10

    available = readers()
    if not available:
        print("No smart card readers found.")
        return 1

    print("Readers:")
    for reader in available:
        print(f"  {reader}")

    print(f"Waiting up to {timeout}s for a card...")
    request = CardRequest(timeout=timeout, cardType=AnyCardType())

    try:
        service = request.waitforcard()
        service.connection.connect()
    except CardRequestTimeoutException:
        print("Timed out waiting for a card.")
        return 2
    except NoCardException:
        print("No card present.")
        return 3

    atr = service.connection.getATR()
    print("ATR:", toHexString(atr))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
