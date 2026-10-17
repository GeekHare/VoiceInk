"""Preflight regressions; no network, installation, sudo, or real Xcode needed.

Run on macOS with: python3 -m unittest discover -s scripts/tests -v
"""
import os
import pty
import select
import shlex
import time
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'build-local-macos.sh'


@unittest.skipUnless(os.uname().sysname == 'Darwin', 'macOS bootstrap')
class BootstrapPreflightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='voiceink test ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        scripts = self.root / 'scripts'
        scripts.mkdir()
        self.script = scripts / SOURCE.name
        shutil.copy2(SOURCE, self.script)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.developer = self.root / 'Xcode with spaces.app/Contents/Developer'
        (self.developer / 'usr/bin').mkdir(parents=True)
        self.executable(self.developer / 'usr/bin/xcodebuild', '#!/bin/bash\nexit 0\n')
        self.executable(self.bin / 'xcodebuild', '''#!/bin/bash
case "$1" in
  -version) printf 'Xcode %s\\nBuild version test\\n' "${TEST_XCODE_VERSION:-27.1}" ;;
  -checkFirstLaunchStatus)
    [[ ! -f "$TEST_READY_FILE" ]] || exit 0
    exit "${TEST_FIRST_LAUNCH_STATUS:-0}" ;;
  -runFirstLaunch) echo 'You have not agreed to the Xcode license agreements'; exit 77 ;;
  *) echo 'Unexpected Xcode mutation' >&2; exit 99 ;;
esac
''')
        self.executable(self.bin / 'xcrun', '''#!/bin/bash
case "$*" in
  *--show-sdk-path*) echo '/mock SDK/MacOSX.sdk' ;;
  --find*) echo "/mock tools/$2" ;;
  *) exit 99 ;;
esac
''')
        self.executable(self.bin / 'sudo', '#!/bin/bash\necho "UNEXPECTED_SUDO" >&2\nexit 99\n')
        self.env = dict(os.environ, PATH=str(self.bin) + ':/usr/bin:/bin:/usr/sbin:/sbin',
                        DEVELOPER_DIR=str(self.developer),
                        TEST_READY_FILE=str(self.root / "xcode-ready"))

    @staticmethod
    def executable(path, text):
        path.write_text(text)
        path.chmod(0o755)

    def run_script(self, *args):
        return subprocess.run(['/bin/bash', str(self.script), *args],
                              cwd='/', env=self.env, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True)

    def test_help_has_no_side_effects(self):
        result = self.run_script('--help')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('--install', result.stdout)
        self.assertFalse((self.root / '.local-build').exists())

    def test_unknown_option_fails_before_setup(self):
        result = self.run_script('--bogus')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Unknown argument', result.stdout)
        self.assertFalse((self.root / '.local-build').exists())

    def test_missing_output_value_is_actionable(self):
        result = self.run_script('--output')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('--output requires a path', result.stdout)

    def test_invalid_explicit_xcode_does_not_silently_fall_back(self):
        self.env['DEVELOPER_DIR'] = str(self.root / 'missing')
        result = self.run_script('--check')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Invalid DEVELOPER_DIR', result.stdout)

    def test_old_xcode_fails_before_build_or_download(self):
        self.env['TEST_XCODE_VERSION'] = '16.4'
        result = self.run_script('--check')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Xcode 26+', result.stdout)
        self.assertFalse((self.root / '.local-build').exists())

    def test_check_never_runs_first_launch_or_sudo(self):
        self.env['TEST_FIRST_LAUNCH_STATUS'] = '1'
        result = self.run_script('--check')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Finish Xcode first-launch setup', result.stdout)
        self.assertNotIn('UNEXPECTED_SUDO', result.stdout)
        self.assertFalse((self.root / '.local-build').exists())

    def test_ready_check_handles_spaces_and_other_working_directory(self):
        result = self.run_script('--check')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn(str(self.developer), result.stdout)
        self.assertIn('Prerequisites OK', result.stdout)
        self.assertFalse((self.root / '.local-build').exists())


    def fake_cmake_stop(self):
        cmake = self.root / '.local-build/tools/cmake-3.31.8-macos-universal/CMake.app/Contents/bin/cmake'
        cmake.parent.mkdir(parents=True)
        self.executable(cmake, '#!/bin/bash\necho FAKE_CMAKE_STOP\nexit 88\n')

    def test_noninteractive_license_failure_exits_without_waiting(self):
        self.env['TEST_FIRST_LAUNCH_STATUS'] = '1'
        result = self.run_script('--non-interactive', '--no-install-xcode')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('accept its license', result.stdout)
        self.assertNotIn('[Enter]', result.stdout)
        self.assertNotIn('UNEXPECTED_SUDO', result.stdout)
        self.assertIn('Log:', result.stdout)
        self.assertIn(str(self.script), shlex.split(result.stdout.splitlines()[-1]))

    def test_default_arguments_and_logging_work_without_dev_fd(self):
        self.fake_cmake_stop()
        result = self.run_script()
        self.assertEqual(result.returncode, 88, result.stdout)
        self.assertIn('FAKE_CMAKE_STOP', result.stdout)
        self.assertIn('Preparing CMake', result.stdout)
        logs = list((self.root / '.local-build/logs').glob('*.log'))
        self.assertEqual(len(logs), 1)
        self.assertIn('FAKE_CMAKE_STOP', logs[0].read_text())

    def interactive_run(self, complete_setup):
        self.env['TEST_FIRST_LAUNCH_STATUS'] = '1'
        self.fake_cmake_stop()
        master, slave = pty.openpty()
        proc = subprocess.Popen(['/bin/bash', str(self.script), '--no-install-xcode'],
                                env=self.env, cwd='/', stdin=slave, stdout=slave,
                                stderr=subprocess.STDOUT)
        os.close(slave)
        output = bytearray()
        answered = False
        deadline = time.monotonic() + 15
        try:
            while time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.1)
                if ready:
                    try:
                        data = os.read(master, 65536)
                    except OSError:
                        break  # PTY closes with EIO after the command exits.
                    if not data:
                        break
                    output.extend(data)
                    if b'[Enter]' in output and not answered:
                        if complete_setup:
                            (self.root / 'xcode-ready').touch()
                            os.write(master, b'\n')
                        else:
                            os.write(master, b'q\n')
                        answered = True
                elif proc.poll() is not None:
                    break
            result = proc.wait(timeout=2)
            self.assertTrue(answered, output.decode(errors='replace'))
            return result, output.decode(errors='replace')
        finally:
            if proc.poll() is None:
                # Release a child waiting on the terminal before stopping parent.
                os.write(master, b'q\n')
                proc.kill()
                proc.wait()
            os.close(master)

    def test_interactive_manual_setup_resumes_in_same_run(self):
        code, output = self.interactive_run(complete_setup=True)
        self.assertEqual(code, 88, output)  # Deliberate stop before any download.
        self.assertIn('Preparing CMake', output)
        self.assertIn('FAKE_CMAKE_STOP', output)
        self.assertNotIn('UNEXPECTED_SUDO', output)

    def test_interactive_quit_does_not_start_dependency_installation(self):
        code, output = self.interactive_run(complete_setup=False)
        self.assertEqual(code, 130, output)
        self.assertNotIn('Preparing CMake', output)
        self.assertNotIn('FAKE_CMAKE_STOP', output)


if __name__ == '__main__':
    unittest.main()
