#!/usr/bin/env python3
"""
PSCD unit tests — covers ABI decoding, symbol normalization, batch
step computation, and the verdict logic. No network calls.
"""
import os
import sys
import unittest
from unittest.mock import patch, MagicMock

# Allow `import check` from this test script's directory
SCRIPT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts")
sys.path.insert(0, SCRIPT_DIR)

import check  # noqa: E402


class TestABIDecodeString(unittest.TestCase):
    def test_decode_abi_string_basic(self):
        # 0x20 (offset=32) + 3 (length) + 0x55534443 (USDC) padded to 32 bytes
        # This is the actual abi-encoded string "USDC" returned by symbol()
        hex_raw = (
            "0x"
            "0000000000000000000000000000000000000000000000000000000000000020"  # offset 32
            "0000000000000000000000000000000000000000000000000000000000000004"  # length 4
            "5553444300000000000000000000000000000000000000000000000000000000"  # "USDC" + padding
        )
        self.assertEqual(check.decode_abi_string(hex_raw), "USDC")

    def test_decode_abi_string_empty(self):
        self.assertEqual(check.decode_abi_string("0x"), "")
        self.assertEqual(check.decode_abi_string(""), "")

    def test_decode_abi_string_short_symbol_2chars(self):
        # 2-char symbol "SK"
        hex_raw = (
            "0x"
            "0000000000000000000000000000000000000000000000000000000000000020"
            "0000000000000000000000000000000000000000000000000000000000000002"
            "534b000000000000000000000000000000000000000000000000000000000000"
        )
        self.assertEqual(check.decode_abi_string(hex_raw), "SK")

    def test_decode_abi_string_long_symbol_10chars(self):
        # 10-char symbol
        sym = "0123456789"
        sym_hex = sym.encode("utf-8").hex().ljust(64, "0")
        hex_raw = (
            "0x"
            "0000000000000000000000000000000000000000000000000000000000000020"
            "000000000000000000000000000000000000000000000000000000000000000a"
            + sym_hex
        )
        self.assertEqual(check.decode_abi_string(hex_raw), sym)

    def test_decode_abi_string_handles_truncated_input(self):
        # Less than 128 hex chars (no length field) — should return empty, not raise
        self.assertEqual(check.decode_abi_string("0x1234"), "")

    def test_decode_abi_string_unicode_emoji(self):
        # A symbol with an emoji (unusual but technically valid UTF-8)
        sym = "🚀MOON"
        sym_bytes = sym.encode("utf-8")
        sym_len = len(sym_bytes)
        sym_hex = sym_bytes.hex().ljust(64, "0")
        hex_raw = (
            "0x"
            "0000000000000000000000000000000000000000000000000000000000000020"
            f"{sym_len:064x}"
            + sym_hex
        )
        self.assertEqual(check.decode_abi_string(hex_raw), sym)


class TestDecodeUint8(unittest.TestCase):
    def test_decode_abi_uint8_18(self):
        # 18 = 0x12, last byte of 32-byte uint256
        hex_raw = "0x" + "0" * 62 + "12"
        self.assertEqual(check.decode_abi_uint8(hex_raw), 18)

    def test_decode_abi_uint8_6(self):
        hex_raw = "0x" + "0" * 62 + "06"
        self.assertEqual(check.decode_abi_uint8(hex_raw), 6)

    def test_decode_abi_uint8_0_fallback(self):
        # Empty result defaults to 18
        self.assertEqual(check.decode_abi_uint8("0x"), 18)


class TestNormalizeSymbol(unittest.TestCase):
    def test_uppercase(self):
        self.assertEqual(check.normalize_symbol("usdc"), "USDC")
        self.assertEqual(check.normalize_symbol("UsDc"), "USDC")

    def test_strip_whitespace(self):
        self.assertEqual(check.normalize_symbol("  USDC  "), "USDC")
        self.assertEqual(check.normalize_symbol("\tUSDC\n"), "USDC")

    def test_empty(self):
        self.assertEqual(check.normalize_symbol(""), "")
        self.assertEqual(check.normalize_symbol("   "), "")

    def test_none_safe(self):
        self.assertEqual(check.normalize_symbol(None), "")


class TestHexHelpers(unittest.TestCase):
    def test_hex_to_int(self):
        self.assertEqual(check.hex_to_int("0x10"), 16)
        self.assertEqual(check.hex_to_int("0xff"), 255)
        self.assertEqual(check.hex_to_int("0x0"), 0)
        self.assertEqual(check.hex_to_int(None), 0)

    def test_int_to_hex(self):
        self.assertEqual(check.int_to_hex(16), "0x10")
        self.assertEqual(check.int_to_hex(255), "0xff")
        self.assertEqual(check.int_to_hex(0), "0x0")


class TestCheckSymbol(unittest.TestCase):
    """Test the high-level check_symbol() verdict logic with mocked RPC."""

    def _mock_token_meta(self, address, symbol, name="", decimals=18):
        return (address, {
            "symbol": symbol, "name": name, "decimals": decimals,
            "ok": True, "error": None,
        })

    @patch("check.fetch_token_meta_parallel")
    @patch("check.scan_token_addrs")
    def test_verdict_clear_when_no_match(self, mock_scan, mock_meta):
        mock_scan.return_value = {"0xaaa", "0xbbb"}
        mock_meta.return_value = dict([
            self._mock_token_meta("0xaaa", "USDT"),
            self._mock_token_meta("0xbbb", "DAI"),
        ])
        r = check.check_symbol("mainnet", "SKP", 0, 100, step=100, max_workers=2, progress=False)
        self.assertEqual(r["verdict"], "CLEAR")
        self.assertEqual(r["candidate"], "SKP")
        self.assertEqual(r["normalized"], "SKP")
        self.assertEqual(r["collisions"], [])

    @patch("check.fetch_token_meta_parallel")
    @patch("check.scan_token_addrs")
    def test_verdict_collision_on_exact_match(self, mock_scan, mock_meta):
        mock_scan.return_value = {"0xaaa", "0xbbb", "0xccc"}
        mock_meta.return_value = dict([
            self._mock_token_meta("0xaaa", "USDC", name="USD Coin", decimals=6),
            self._mock_token_meta("0xbbb", "USDT", name="Tether"),
            self._mock_token_meta("0xccc", "SKP",  name="Sakipatla", decimals=18),
        ])
        r = check.check_symbol("mainnet", "SKP", 0, 100, step=100, max_workers=2, progress=False)
        self.assertEqual(r["verdict"], "COLLISION")
        self.assertEqual(len(r["collisions"]), 1)
        self.assertEqual(r["collisions"][0]["address"], "0xccc")
        self.assertEqual(r["collisions"][0]["symbol"], "SKP")

    @patch("check.fetch_token_meta_parallel")
    @patch("check.scan_token_addrs")
    def test_verdict_collision_case_insensitive(self, mock_scan, mock_meta):
        # Symbol on chain: "skp" (lowercase), user query: "SKP" → still matches
        mock_scan.return_value = {"0xaaa"}
        mock_meta.return_value = dict([
            self._mock_token_meta("0xaaa", "skp"),
        ])
        r = check.check_symbol("mainnet", "SKP", 0, 100, step=100, max_workers=2, progress=False)
        self.assertEqual(r["verdict"], "COLLISION")

    @patch("check.fetch_token_meta_parallel")
    @patch("check.scan_token_addrs")
    def test_verdict_empty_candidate(self, mock_scan, mock_meta):
        mock_scan.return_value = set()
        mock_meta.return_value = {}
        r = check.check_symbol("mainnet", "", 0, 100, step=100, max_workers=2, progress=False)
        self.assertEqual(r["verdict"], "EMPTY")

    @patch("check.fetch_token_meta_parallel")
    @patch("check.scan_token_addrs")
    def test_multiple_collisions_all_reported(self, mock_scan, mock_meta):
        # 2 distinct contracts using the same symbol "FAKE"
        mock_scan.return_value = {"0xaaa", "0xbbb", "0xccc"}
        mock_meta.return_value = dict([
            self._mock_token_meta("0xaaa", "FAKE", "Fake Token 1", 18),
            self._mock_token_meta("0xbbb", "FAKE", "Fake Token 2", 6),
            self._mock_token_meta("0xccc", "REAL", "Real", 18),
        ])
        r = check.check_symbol("mainnet", "FAKE", 0, 100, step=100, max_workers=2, progress=False)
        self.assertEqual(r["verdict"], "COLLISION")
        self.assertEqual(len(r["collisions"]), 2)
        addrs = sorted(c["address"] for c in r["collisions"])
        self.assertEqual(addrs, ["0xaaa", "0xbbb"])

    @patch("check.fetch_token_meta_parallel")
    @patch("check.scan_token_addrs")
    def test_block_range_recorded(self, mock_scan, mock_meta):
        mock_scan.return_value = set()
        mock_meta.return_value = {}
        r = check.check_symbol("mainnet", "X", 1000, 2000, step=100, max_workers=2, progress=False)
        self.assertEqual(r["from_block"], 1000)
        self.assertEqual(r["to_block"], 2000)
        self.assertEqual(r["blocks"], 1001)


class TestScanTokenAddrs(unittest.TestCase):
    @patch("check.rpc")
    def test_collects_unique_addresses_from_mints(self, mock_rpc):
        # Simulate 2 batches: each returns some Transfer-from-zero logs
        def fake_rpc(url, method, params, attempt=0):
            if method == "eth_getLogs":
                batch = params[0]
                if batch["fromBlock"] == "0x0":
                    return [
                        {"address": "0xaaa", "topics": [check.ZERO_TOPIC]},
                        {"address": "0xbbb", "topics": [check.ZERO_TOPIC]},
                    ]
                else:
                    return [
                        {"address": "0xaaa", "topics": [check.ZERO_TOPIC]},  # dup
                        {"address": "0xccc", "topics": [check.ZERO_TOPIC]},
                    ]
            return "0x0"
        mock_rpc.side_effect = fake_rpc
        addrs = check.scan_token_addrs("http://x", 0, 1999, step=1000, progress=False)
        self.assertEqual(addrs, {"0xaaa", "0xbbb", "0xccc"})

    @patch("check.rpc")
    def test_scan_handles_empty_logs(self, mock_rpc):
        # When RPC returns no logs, the set should be empty
        mock_rpc.return_value = []
        addrs = check.scan_token_addrs("http://x", 0, 999, step=1000, progress=False)
        self.assertEqual(addrs, set())

    @patch("check.rpc")
    def test_scan_handles_none_logs(self, mock_rpc):
        # RPC can return null when there are no logs
        mock_rpc.return_value = None
        addrs = check.scan_token_addrs("http://x", 0, 999, step=1000, progress=False)
        self.assertEqual(addrs, set())


class TestRenderMarkdown(unittest.TestCase):
    def _render(self, r):
        """Capture stdout while calling render_markdown (it both prints and returns 0)."""
        import io
        from contextlib import redirect_stdout
        buf = io.StringIO()
        with redirect_stdout(buf):
            check.render_markdown(r)
        return buf.getvalue()

    def test_clear_verdict_renders_all_clear_section(self):
        r = {
            "network": "Pharos Pacific Ocean Mainnet",
            "chainId": 1672,
            "candidate": "SKP",
            "normalized": "SKP",
            "from_block": 0, "to_block": 9999, "blocks": 10000,
            "tokens_seen": 5, "tokens_ok": 5,
            "verdict": "CLEAR",
            "verdict_msg": "no token uses SKP",
            "collisions": [],
        }
        out = self._render(r)
        self.assertIn("CLEAR", out)
        self.assertIn("All clear", out)
        self.assertIn("`SKP`", out)
        # Should NOT mention collisions
        self.assertNotIn("collision(s) found", out)

    def test_collision_verdict_renders_table(self):
        r = {
            "network": "Pharos Pacific Ocean Mainnet",
            "chainId": 1672,
            "candidate": "USDC",
            "normalized": "USDC",
            "from_block": 0, "to_block": 9999, "blocks": 10000,
            "tokens_seen": 50, "tokens_ok": 48,
            "verdict": "COLLISION",
            "verdict_msg": "1 token uses USDC",
            "collisions": [
                {
                    "address": "0x1234567890abcdef1234567890abcdef12345678",
                    "symbol": "USDC", "name": "USD Coin", "decimals": 6,
                    "ok": True, "error": None,
                    "explorer": "https://www.pharosscan.xyz/token/0x1234567890abcdef1234567890abcdef12345678",
                },
            ],
        }
        out = self._render(r)
        self.assertIn("COLLISION", out)
        self.assertIn("1 collision(s) found", out)
        self.assertIn("USD Coin", out)
        self.assertIn("`0x12345678…345678`", out)
        self.assertIn("pharosscan.xyz", out)


def main():
    loader = unittest.TestLoader()
    suite = loader.loadTestsFromModule(sys.modules[__name__])
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)


if __name__ == "__main__":
    main()
