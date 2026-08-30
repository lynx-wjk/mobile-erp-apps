#!/usr/bin/env python3
"""
Master E2E Test Suite Runner for Mobile ERP Enterprise Landing Page.
Executes all test tiers (Tiers 1-5) and outputs comprehensive diagnostics.
Usage: python tests/run_e2e_tests.py
"""

import os
import sys
import time
import unittest
from pathlib import Path

# Add project root to sys.path
PROJECT_ROOT = Path(__file__).resolve().parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

# Ensure UTF-8 output encoding if possible
if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

from tests.tier1_feature_coverage import TestTier1FeatureCoverage
from tests.tier2_boundary_cases import TestTier2BoundaryCases
from tests.tier3_cross_feature import TestTier3CrossFeature
from tests.tier4_user_workloads import TestTier4UserWorkloads
from tests.tier5_adversarial import TestTier5Adversarial


class PrettyTestResult(unittest.TestResult):
    def __init__(self, stream, descriptions, verbosity):
        super().__init__(stream, descriptions, verbosity)
        self.stream = stream
        self.verbosity = verbosity
        self.successes = []

    def _writeln(self, message: str = ""):
        self.stream.write(message + "\n")
        self.stream.flush()

    def addSuccess(self, test):
        super().addSuccess(test)
        self.successes.append(test)
        doc = test.shortDescription() or test._testMethodName
        self._writeln(f"  [PASS] {doc}")

    def addFailure(self, test, err):
        super().addFailure(test, err)
        doc = test.shortDescription() or test._testMethodName
        self._writeln(f"  [FAIL] {doc}")

    def addError(self, test, err):
        super().addError(test, err)
        doc = test.shortDescription() or test._testMethodName
        self._writeln(f"  [ERROR] {doc}")


class PrettyTestRunner:
    def __init__(self, stream=sys.stdout, verbosity=1):
        self.stream = stream
        self.verbosity = verbosity

    def _writeln(self, message: str = ""):
        self.stream.write(message + "\n")
        self.stream.flush()

    def run_tier(self, tier_name: str, tier_desc: str, test_case_class) -> unittest.TestResult:
        self._writeln("=" * 80)
        self._writeln(f"  {tier_name.upper()}: {tier_desc}")
        self._writeln("=" * 80)
        
        suite = unittest.TestLoader().loadTestsFromTestCase(test_case_class)
        result = PrettyTestResult(self.stream, None, self.verbosity)
        start_time = time.time()
        suite.run(result)
        elapsed = time.time() - start_time
        
        passed_count = len(result.successes)
        failed_count = len(result.failures)
        error_count = len(result.errors)
        total_count = result.testsRun

        self._writeln("-" * 80)
        self._writeln(
            f"  {tier_name} Summary: {passed_count}/{total_count} Passed "
            f"({failed_count} Failures, {error_count} Errors) in {elapsed:.3f}s"
        )
        self._writeln("")
        return result


def main():
    runner = PrettyTestRunner()
    tiers = [
        ("Tier 1", "Feature Coverage (Primary Capabilities)", TestTier1FeatureCoverage),
        ("Tier 2", "Boundary & Corner Cases (Edge & Error Handling)", TestTier2BoundaryCases),
        ("Tier 3", "Cross-Feature Interactions & Architecture Alignment", TestTier3CrossFeature),
        ("Tier 4", "Real-World User Workloads & Persona Journeys", TestTier4UserWorkloads),
        ("Tier 5", "Adversarial Hardening & Forensic Security Audits", TestTier5Adversarial),
    ]

    total_tests = 0
    total_passed = 0
    total_failed = 0
    total_errors = 0
    all_failure_details = []

    print("\n" + "#" * 80)
    print("  MOBILE ERP ENTERPRISE LANDING PAGE — AUTOMATED E2E TEST SUITE")
    print("  Target: https://mdhproduction.com | Directory: landing_page/")
    print("#" * 80 + "\n")

    overall_start = time.time()

    for tier_id, tier_name, test_class in tiers:
        result = runner.run_tier(tier_id, tier_name, test_class)
        total_tests += result.testsRun
        total_passed += len(result.successes)
        total_failed += len(result.failures)
        total_errors += len(result.errors)
        
        for test, err in result.failures:
            all_failure_details.append((tier_id, test, "FAILURE", err))
        for test, err in result.errors:
            all_failure_details.append((tier_id, test, "ERROR", err))

    total_elapsed = time.time() - overall_start

    print("=" * 80)
    print("  FINAL E2E EXECUTION SUMMARY")
    print("=" * 80)
    print(f"  Total Test Cases Executed : {total_tests}")
    print(f"  Passed                    : {total_passed}")
    print(f"  Failed                    : {total_failed}")
    print(f"  Errors                    : {total_errors}")
    print(f"  Total Execution Time      : {total_elapsed:.3f} seconds")
    print("=" * 80)

    if all_failure_details:
        print("\n" + "!" * 80)
        print("  DIAGNOSTIC FAILURE DETAILS (IMPLEMENTATION BUGS TO ESCALATE)")
        print("!" * 80 + "\n")
        for tier_id, test, status, err in all_failure_details:
            print(f"[{tier_id}] {test.id()} -> {status}")
            print(err.strip())
            print("-" * 80)
        print("\nResult: SUITE REPORTED DEFECTS (See above diagnostics for milestone fixes).\n")
        return 1
    else:
        print("\nResult: ALL E2E TEST TIERS PASSED (100% SUCCESS).\n")
        return 0


if __name__ == "__main__":
    sys.exit(main())
