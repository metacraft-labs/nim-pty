import copy
import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    "nix_derivation_source", Path(__file__).with_name("read-nix-derivation-source.py"))
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)

DRV = "/nix/store/dg8s5zbwf6nipb9cpgv1qsgpjsl7csxw-runquota-0.1.0.drv"
OUTPUT = "/nix/store/aagifqraqhy8sdj741s7dassf4c1lqmk-runquota-0.1.0"
SOURCE = "/nix/store/3c5sm20q040pnch671790fy0rgx0w6kd-a196qnvz2h12d8lbcmlkif88qxyzwj8x-source"
SYSTEM = "x86_64-linux"


def version_four():
    return {"version": 4, "derivations": {Path(DRV).name: {
        "version": 4, "system": SYSTEM,
        "outputs": {"out": {"path": Path(OUTPUT).name}},
        "env": {"src": SOURCE}}}}


def version_three():
    derivations = version_four()["derivations"]
    derivations[Path(DRV).name]["version"] = 3
    return derivations


def legacy():
    derivation = version_four()["derivations"][Path(DRV).name]
    del derivation["version"]
    derivation["outputs"]["out"]["path"] = OUTPUT
    return {DRV: derivation}


class DerivationSourceTests(unittest.TestCase):
    def read(self, document, derivation=DRV, output=OUTPUT, system=SYSTEM):
        return reader.derivation_source(document, derivation, output, system)

    def test_version_four_fields_from_retained_linux_artifact(self):
        self.assertEqual(self.read(version_four()), SOURCE)

    def test_legacy_flat_derivation(self):
        self.assertEqual(self.read(legacy()), SOURCE)
        for version in (1, 2):
            document = legacy()
            document[DRV]["version"] = version
            with self.subTest(version=version):
                self.assertEqual(self.read(document), SOURCE)

    def test_refuses_explicit_unknown_legacy_version(self):
        for version in (None, True, 3, 4):
            document = legacy()
            document[DRV]["version"] = version
            with self.subTest(version=version), self.assertRaises(ValueError):
                self.read(document)

    def test_version_three_flat_basename_derivation(self):
        self.assertEqual(self.read(version_three()), SOURCE)

    def test_refuses_wrong_selected_identity(self):
        for document in (version_four(), version_three(), legacy()):
            for arguments in ({"derivation": DRV + "-foreign"},
                              {"output": OUTPUT + "-foreign"},
                              {"system": "aarch64-linux"}):
                with self.subTest(arguments=arguments), self.assertRaises(ValueError):
                    self.read(document, **arguments)

    def test_refuses_unsupported_or_malformed_envelope(self):
        for field, value in (("version", 3), ("version", True),
                             ("derivations", []), ("extra", "unexpected")):
            document = version_four()
            document[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                self.read(document)

    def test_refuses_multiple_derivations(self):
        document = version_four()
        document["derivations"]["foreign.drv"] = copy.deepcopy(
            document["derivations"][Path(DRV).name])
        with self.assertRaises(ValueError):
            self.read(document)

    def test_refuses_wrong_inner_version_or_source(self):
        for field, value in (("version", 3), ("version", True),
                             ("env", {"src": "/tmp/foreign-source"})):
            document = version_four()
            document["derivations"][Path(DRV).name][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                self.read(document)

    def test_refuses_unknown_flat_basename_version(self):
        for version in (None, True, 4):
            document = version_three()
            document[Path(DRV).name]["version"] = version
            with self.subTest(version=version), self.assertRaises(ValueError):
                self.read(document)


if __name__ == "__main__":
    unittest.main()
