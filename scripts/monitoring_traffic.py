"""Generate local demo traffic, including a controlled HTTP 404 spike."""

import argparse
import time
import urllib.error
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--duration", type=int, default=180)
    args = parser.parse_args()
    started = time.monotonic()
    requests = 0
    errors = 0
    while (elapsed := time.monotonic() - started) < args.duration:
        # Middle third of the demo: 20% known client errors, not injected server failures.
        spike = args.duration / 3 <= elapsed < args.duration * 2 / 3
        path = "/intentional-demo-error" if spike and requests % 5 == 0 else "/"
        try:
            with urllib.request.urlopen("http://app:8080" + path, timeout=2) as response:
                response.read()
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
            errors += 1
        requests += 1
        time.sleep(0.05)
    print(f"Demo complete: {requests} requests, {errors} intentional HTTP 404 responses.")


if __name__ == "__main__":
    main()
