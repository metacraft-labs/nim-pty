"""Read the selected derivation's source from legacy, v3 or v4 Nix JSON."""

import json
from pathlib import PurePosixPath
import sys


def derivation_source(document, expected_derivation, expected_output, system):
    if not isinstance(document, dict):
        raise ValueError("Nix derivations must be an object")
    if "derivations" in document or "version" in document:
        if (set(document) != {"derivations", "version"}
                or type(document["version"]) is not int
                or document["version"] != 4):
            raise ValueError("Unsupported Nix derivation envelope")
        derivations = document["derivations"]
        key = PurePosixPath(expected_derivation).name
        expected_version = 4
    else:
        derivations = document
        if set(document) == {expected_derivation}:
            key = expected_derivation
            expected_version = None
        else:
            key = PurePosixPath(expected_derivation).name
            expected_version = 3
    if not isinstance(derivations, dict) or set(derivations) != {key}:
        raise ValueError("Nix did not return exactly the selected derivation")
    derivation = derivations[key]
    if not isinstance(derivation, dict):
        raise ValueError("Invalid Nix derivation")
    version = derivation.get("version")
    if expected_version is not None and (type(version) is not int
                                         or version != expected_version):
        raise ValueError("Unsupported Nix derivation version")
    if expected_version is None and "version" in derivation and (
            type(version) is not int or version not in (1, 2)):
        raise ValueError("Unsupported legacy Nix derivation version")
    if derivation.get("system") != system:
        raise ValueError("Nix derivation has the wrong system")
    output = derivation["outputs"]["out"]["path"]
    if output not in (expected_output, PurePosixPath(expected_output).name):
        raise ValueError("Nix derivation has the wrong output")
    source = derivation["env"]["src"]
    if not isinstance(source, str) or PurePosixPath(source).parent != PurePosixPath("/nix/store"):
        raise ValueError("Nix derivation source is not a store path")
    return source


def main():
    raw, derivation, output, system = sys.argv[1:]
    with open(raw, encoding="utf-8") as stream:
        document = json.load(stream)
    print(derivation_source(document, derivation, output, system))


if __name__ == "__main__":
    main()
