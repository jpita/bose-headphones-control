import os
import re
import sys
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, os.path.join(ROOT, "vendor"))

from pybmap.constants import ACTION_MODES, BUTTON_EVENTS, BUTTON_IDS  # noqa: E402

SWIFT_FILES = [
    "native-swift-macos/BoseBMAP.swift",
    "native-ios/BoseHeadphonesControl/BoseBMAP.swift",
]


def swift_table(source, name):
    block = re.search(r"let %s: \[Int: String\] = \[(.*?)\n?\]" % name, source, re.S)
    if not block:
        raise AssertionError("table %s not found" % name)
    return {int(k): v for k, v in re.findall(r'(\d+): "([^"]+)"', block.group(1))}


class SwiftTablesMatchPybmap(unittest.TestCase):
    def test_tables_match(self):
        for path in SWIFT_FILES:
            with open(os.path.join(ROOT, path)) as f:
                source = f.read()
            with self.subTest(path=path):
                self.assertEqual(swift_table(source, "bmapActionNames"), ACTION_MODES)
                self.assertEqual(swift_table(source, "bmapEventNames"), BUTTON_EVENTS)
                self.assertEqual(swift_table(source, "bmapButtonNames"), BUTTON_IDS)

    def test_swift_copies_are_identical(self):
        contents = []
        for path in SWIFT_FILES:
            with open(os.path.join(ROOT, path)) as f:
                contents.append(f.read())
        self.assertEqual(contents[0], contents[1])


if __name__ == "__main__":
    unittest.main()
