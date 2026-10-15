#!/usr/bin/env python3
"""Generate real ToggleMaster evaluations so the evaluation service emits SQS events.

Uses only Python's standard library. It does not send synthetic/malformed bodies directly
into SQS; it calls the application's /evaluation/evaluate endpoint instead.
"""

from __future__ import annotations

import argparse
import statistics
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


def main() -> int:
    parser = argparse.ArgumentParser(description="Load test the ToggleMaster evaluation endpoint")
    parser.add_argument("--base-url", required=True, help="Base URL ending in /evaluation, e.g. http://<ALB-DNS>/evaluation")
    parser.add_argument("--requests", type=int, default=500, help="Number of GET requests (default: 500)")
    parser.add_argument("--concurrency", type=int, default=25, help="Concurrent requests (default: 25)")
    parser.add_argument("--flag-name", default="enable-new-dashboard", help="Existing flag name")
    parser.add_argument("--timeout", type=float, default=10.0, help="Per-request timeout in seconds")
    args = parser.parse_args()

    if args.requests < 1 or args.concurrency < 1:
        parser.error("--requests and --concurrency must both be >= 1")

    base = args.base_url.rstrip("/")
    durations: list[float] = []
    statuses: Counter[str] = Counter()
    errors: list[str] = []
    start = time.perf_counter()

    def send_one(index: int) -> tuple[str, float, str | None]:
        query = urlencode({"user_id": f"keda-load-test-{index}", "flag_name": args.flag_name})
        url = f"{base}/evaluate?{query}"
        request = Request(url, headers={"User-Agent": "ToggleMaster-KEDA-load-test/1.0"})
        request_start = time.perf_counter()
        try:
            with urlopen(request, timeout=args.timeout) as response:
                response.read()
                code = str(response.status)
                detail = None if 200 <= response.status < 300 else f"HTTP {response.status} for request {index}"
        except HTTPError as exc:
            code = str(exc.code)
            detail = f"HTTP {exc.code} for request {index}"
        except (URLError, TimeoutError, OSError) as exc:
            code = "ERROR"
            detail = f"Request {index}: {exc}"
        return code, time.perf_counter() - request_start, detail

    print(f"Target: {base}/evaluate")
    print(f"Requests: {args.requests} | Concurrency: {args.concurrency} | Flag: {args.flag_name}")
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        futures = [pool.submit(send_one, i) for i in range(1, args.requests + 1)]
        for future in as_completed(futures):
            code, duration, detail = future.result()
            statuses[code] += 1
            durations.append(duration)
            if detail and len(errors) < 10:
                errors.append(detail)

    elapsed = time.perf_counter() - start
    durations_sorted = sorted(durations)
    p95_index = max(0, min(len(durations_sorted) - 1, int(0.95 * len(durations_sorted)) - 1))
    print("\n--- Results ---")
    print(f"Total elapsed: {elapsed:.2f}s")
    print(f"Throughput: {len(durations) / elapsed:.1f} requests/s")
    print(f"HTTP status counts: {dict(statuses)}")
    if durations:
        print(f"Latency average: {statistics.mean(durations) * 1000:.0f} ms")
        print(f"Latency p95: {durations_sorted[p95_index] * 1000:.0f} ms")
    if errors:
        print("Sample errors:")
        for item in errors:
            print(f"  - {item}")
    success = statuses.get("200", 0) + statuses.get("201", 0) + statuses.get("204", 0)
    print(f"Successful 2xx responses: {success}/{args.requests}")
    return 0 if success > 0 and not statuses.get("ERROR") else 1


if __name__ == "__main__":
    raise SystemExit(main())
