"""Guards the offline contract between SwiftPM plugin sandboxes and Cargo.

SwiftPM runs build-tool plugins without network access, so every Rust module
built by a plugin must resolve from a pre-populated Cargo cache. These checks
fail when a build script starts downloading at build time or when CI stops
preparing that cache before Swift builds.
"""
from pathlib import Path
import os
import re
import unittest

REPO = Path(__file__).resolve().parents[2]


class RustBuildOfflineTests(unittest.TestCase):
    def crates(self):
        return sorted((REPO / 'Modules').glob('*/Cargo.toml'))

    def cargo_build_scripts(self):
        scripts = []
        for script in sorted((REPO / 'Modules').glob('*/*.sh')):
            text = script.read_text()
            if re.search(r'"\$cargo_bin"\s+build\b', text):
                scripts.append((script, text))
        return scripts

    def test_every_module_crate_is_locked_and_built_offline(self):
        crates = self.crates()
        self.assertTrue(crates, 'no Rust crates found under Modules/')
        built = {script.parent for script, _ in self.cargo_build_scripts()}
        for manifest in crates:
            root = manifest.parent
            self.assertTrue((root / 'Cargo.lock').is_file(), f'{root} needs a pinned Cargo.lock')
            self.assertIn(root, built, f'{root} has no plugin build script invoking cargo')
        for script, text in self.cargo_build_scripts():
            self.assertIn('--offline', text, f'{script} must not download inside the SwiftPM sandbox')
            self.assertIn('--locked', text, f'{script} must build the pinned Cargo.lock')

    def test_dependency_fetch_script_covers_every_module(self):
        fetch = REPO / 'scripts/fetch-rust-dependencies.sh'
        self.assertTrue(fetch.is_file())
        self.assertTrue(os.access(fetch, os.X_OK), 'dependency fetch script must be executable')
        text = fetch.read_text()
        self.assertIn('Modules/*/Cargo.toml', text, 'new Rust modules must be discovered automatically')
        self.assertIn('--offline', text, 'fetching must finish by proving the offline cache is complete')
        self.assertIn('--locked', text)
        self.assertIn('plugin_cargo_home', text, 'fetching must target the cache Cargo resolves without HOME')
        self.assertIsNotNone(re.search(r'"\$cargo_bin"\s+vendor\b', text),
                             'the plugin sandbox cannot write CARGO_HOME, so fetching must extract crates')

    def test_ci_prepares_cargo_before_any_swift_build(self):
        workflow = (REPO / '.github/workflows/ci.yml').read_text()
        fetch = workflow.find('scripts/fetch-rust-dependencies.sh')
        self.assertNotEqual(fetch, -1, 'CI must populate Cargo before SwiftPM sandboxes run')
        for command in ('swift test', 'swift build -c release'):
            position = workflow.find(command)
            self.assertNotEqual(position, -1, f'CI is expected to run {command}')
            self.assertLess(fetch, position, f'Cargo dependencies must be fetched before {command}')
        self.assertIn('Modules/*/Cargo.lock', workflow, 'the Cargo cache key must follow the lockfiles')
        self.assertIn('~/.cargo/registry', workflow)

    def test_release_workflow_prepares_cargo_before_its_build(self):
        workflow = (REPO / '.github/workflows/image-release-performance.yml').read_text()
        fetch = workflow.find('scripts/fetch-rust-dependencies.sh')
        self.assertNotEqual(fetch, -1)
        self.assertLess(fetch, workflow.find('Build pinned FlashRaw'))


if __name__ == '__main__':
    unittest.main()
