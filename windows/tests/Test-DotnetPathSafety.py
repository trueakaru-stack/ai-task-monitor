"""Guard test runners against .NET SDK changing the persistent Windows PATH.

This check only reads source files. It does not start .NET or change the registry.
Python checks cover top-level environment dictionaries and recognized subprocess
calls; PowerShell checks cover $values tables and direct & $dotnet launches.
Workflow checks cover job-level and explicit step-level environment in .yml
and .yaml files; the C# check covers the known ClaudeLogWriter child. The check
does not prove arbitrary aliases, control flow, dynamic environment mutations,
third-party process safety, or actual registry behavior.
"""

import ast
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
PROFILE = "DOTNET_CLI_HOME"
OPT_OUT = "DOTNET_ADD_GLOBAL_TOOLS_TO_PATH"
REQUIRED_RUNNERS = {
    "windows/native/Claude/Test-Claude.ps1",
    "windows/native/ClaudeHook/Test-ClaudeHook.ps1",
    "windows/native/ClaudeLogWriter/Test-ClaudeLogWriter.ps1",
    "windows/native/ClaudeReader/Test-ClaudeReader.ps1",
    "windows/native/Codex/Test-Codex.ps1",
    "windows/native/CodexDiscovery/Test-CodexDiscovery.ps1",
    "windows/native/CodexIndex/Test-CodexIndex.ps1",
    "windows/native/Prototype/Test-Prototype.ps1",
    "windows/native/Providers/Test-Providers.ps1",
    "windows/native/ClaudeConfig/Tests/run_synthetic_tests.py",
    "windows/native/CodexLoop/Tests/run_synthetic_tests.py",
    "windows/native/ReleaseMetadata/Tests/run_synthetic_tests.py",
    "windows/native/UpdateController/Tests/run_synthetic_tests.py",
    "windows/native/UpdateRetry/Tests/run_synthetic_tests.py",
    "windows/tests/ClaudeReadShare/run_regression.py",
    ".github/workflows/windows-claude-reader-audit.yml",
    ".github/workflows/windows-claude-reader-safe-audit-20261109.yml",
    ".github/workflows/windows-visible-tab-count-audit-20261109.yml",
}


def dictionary_values(node):
    if isinstance(node, ast.Dict):
        return {key.value: value for key, value in zip(node.keys, node.values)
                if isinstance(key, ast.Constant) and isinstance(key.value, str)}
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "dict":
        return {item.arg: item.value for item in node.keywords if item.arg is not None}
    return {}


def has_opt_out(values):
    flag = values.get(OPT_OUT)
    return isinstance(flag, ast.Constant) and flag.value == "0"


def references_dotnet(node, aliases=frozenset({"dotnet"})):
    for child in ast.walk(node):
        if isinstance(child, ast.Name) and child.id.lower() in aliases:
            return True
        if isinstance(child, ast.Constant) and isinstance(child.value, str):
            if re.search(r"(?:^|[/\\])dotnet(?:\.exe)?$", child.value, re.I):
                return True
    return False


def python_issues(source):
    tree = ast.parse(source)
    homes = [node for node in ast.walk(tree) if isinstance(node, ast.Constant) and node.value == PROFILE]
    covered = set()
    issues = []
    for node in ast.walk(tree):
        if not isinstance(node, (ast.Dict, ast.Call)):
            continue
        values = dictionary_values(node)
        if PROFILE not in values:
            continue
        if isinstance(node, ast.Dict):
            covered.update(id(key) for key in node.keys if isinstance(key, ast.Constant) and key.value == PROFILE)
        if not has_opt_out(values):
            issues.append("the child environment does not disable the SDK PATH update")
    if any(id(home) not in covered for home in homes):
        issues.append("the SDK profile assignment is not covered by this safety check")

    # Follow the explicit top-level environment dictionaries used by these runners.
    environments = {}
    aliases = {"dotnet"}
    functions = {node.name: node for node in tree.body if isinstance(node, ast.FunctionDef)}
    for node in tree.body:
        if isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            for target in targets:
                if isinstance(target, ast.Name):
                    environments[target.id] = dictionary_values(node.value)
                    if node.value is not None and references_dotnet(node.value, aliases):
                        aliases.add(target.id.lower())
        elif (isinstance(node, ast.Expr) and isinstance(node.value, ast.Call)
              and isinstance(node.value.func, ast.Attribute) and node.value.func.attr == "update"
              and isinstance(node.value.func.value, ast.Name) and node.value.args):
            environments.setdefault(node.value.func.value.id, {}).update(dictionary_values(node.value.args[0]))

    def guarded_subprocess(call):
        setting = next((item.value for item in call.keywords if item.arg == "env"), None)
        values = environments.get(setting.id, {}) if isinstance(setting, ast.Name) else dictionary_values(setting)
        return has_opt_out(values)

    def is_subprocess(call):
        return (isinstance(call.func, ast.Attribute) and isinstance(call.func.value, ast.Name)
                and call.func.value.id == "subprocess"
                and call.func.attr in {"run", "Popen", "call", "check_call", "check_output"})

    for node in ast.walk(tree):
        if isinstance(node, ast.Delete):
            if any(isinstance(target, ast.Subscript) and isinstance(target.slice, ast.Constant)
                   and isinstance(target.slice.value, str) and target.slice.value.upper() == OPT_OUT
                   for target in node.targets):
                issues.append("the SDK PATH opt-out is explicitly deleted")
        if isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            for target in targets:
                if (isinstance(target, ast.Subscript) and isinstance(target.slice, ast.Constant)
                        and isinstance(target.slice.value, str) and target.slice.value.upper() == OPT_OUT
                        and not (isinstance(node.value, ast.Constant) and node.value.value == "0")):
                    issues.append("the SDK PATH opt-out is explicitly overwritten")
        if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and node.func.attr == "pop" and node.args and isinstance(node.args[0], ast.Constant)
                and isinstance(node.args[0].value, str) and node.args[0].value.upper() == OPT_OUT):
            issues.append("the SDK PATH opt-out is explicitly removed")
        if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and node.func.attr == "clear" and isinstance(node.func.value, ast.Name)
                and has_opt_out(environments.get(node.func.value.id, {}))):
            issues.append("the protected environment is explicitly cleared")
        if not isinstance(node, ast.Call) or not node.args or not references_dotnet(node.args[0], aliases):
            continue
        if is_subprocess(node):
            if not guarded_subprocess(node):
                issues.append("the dotnet subprocess does not receive a protected environment")
        elif isinstance(node.func, ast.Name) and node.func.id in functions:
            calls = [call for call in ast.walk(functions[node.func.id])
                     if isinstance(call, ast.Call) and is_subprocess(call)]
            if not calls or any(not guarded_subprocess(call) for call in calls):
                issues.append("the dotnet subprocess wrapper does not receive a protected environment")
    return issues


def powershell_issues(source):
    if PROFILE not in source and not re.search(r"\bdotnet(?:\.exe)?\b", source, re.I):
        return []
    tables = re.findall(r"(?ims)\$values\s*=\s*@\{(.*?)^\s*\}", source)
    profiles = [table for table in tables if re.search(r"\b" + PROFILE + r"\s*=", table, re.I)]
    safe_flag = r"\b" + OPT_OUT + r"\s*=\s*['\"]0['\"]"
    issues = ["the child environment does not disable the SDK PATH update"
              for table in profiles if not re.search(safe_flag, table, re.I)]
    assignments = re.finditer(r"(?im)^\s*\$env:" + OPT_OUT + r"\s*=\s*([^\r\n;#]+)", source)
    if any(match.group(1).strip() not in ("'0'", '"0"') for match in assignments):
        issues.append("the process SDK PATH opt-out is explicitly overwritten")
    if re.search(r"(?im)^\s*(?:Remove-Item|ri|rm|del)\b[^\r\n]*(?:Env:|Environment::)\\?" + OPT_OUT + r"\b", source):
        issues.append("the process SDK PATH opt-out is explicitly removed")
    if re.search(r"(?i)\$values\s*\.\s*(?:Remove\s*\(\s*['\"]" + OPT_OUT
                 + r"['\"]|Clear\s*\()", source):
        issues.append("the child SDK PATH opt-out is explicitly removed")
    if re.search(r"(?i)\[Environment\]::SetEnvironmentVariable\s*\(\s*['\"]" + OPT_OUT
                 + r"['\"]\s*,\s*(?:\$null|['\"]\s*['\"])", source):
        issues.append("the process SDK PATH opt-out is explicitly removed")

    # Some runners set process variables directly after clearing the environment.
    starts = list(re.finditer(r"(?im)^\s*&\s*\$dotnet\b", source))
    for start in starts:
        before = source[:start.start()]
        flags = list(re.finditer(r"(?im)^\s*\$env:" + OPT_OUT + r"\s*=\s*([^\r\n;#]+)", before))
        reset = before.lower().rfind("getenvironmentvariables('process').keys")
        if not flags or flags[-1].start() < reset or flags[-1].group(1).strip() not in ("'0'", '"0"'):
            issues.append("the process environment is not protected after reset and before starting .NET")
    if not profiles and not starts:
        issues.append("the .NET launch pattern is not covered by this safety check")
    return issues


def workflow_issues(source):
    if PROFILE not in source and not re.search(r"\bdotnet(?:\.exe)?\b", source, re.I):
        return []
    if "jobs:" not in source:
        return ["the workflow jobs are not covered by this safety check"]
    jobs = re.findall(r"(?ms)^  [A-Za-z_][A-Za-z0-9_-]*:\s*\r?\n(.*?)(?=^  [A-Za-z_][A-Za-z0-9_-]*:\s*\r?\n|\Z)", source.split("jobs:", 1)[1])
    issues = []
    for job in jobs:
        if PROFILE not in job and not re.search(r"\bdotnet(?:\.exe)?\b", job, re.I):
            continue
        before_steps = job.split("    steps:", 1)[0]
        if (not re.search(r"(?m)^    env:\s*$", before_steps)
                or not re.search(r"(?m)^ {6}" + OPT_OUT + r":\s*['\"]0['\"]\s*$", before_steps)):
            issues.append("the job environment is not protected before its first step")
        if "    steps:" in job:
            steps = job.split("    steps:", 1)[1]
            overrides = re.findall(r"(?im)^\s{6,}" + OPT_OUT + r"\s*:\s*([^\r\n#]+)", steps)
            overrides += re.findall(r"(?im)\benv\s*:\s*\{[^\r\n}]*\b" + OPT_OUT
                                    + r"\s*:\s*([^,}\r\n#]+)", steps)
            if any(value.strip() not in ("'0'", '"0"', "0") for value in overrides):
                issues.append("a workflow step overrides the SDK PATH opt-out")
    if not jobs:
        issues.append("the workflow jobs are not covered by this safety check")
    return issues


def is_workflow_file(path):
    return path.suffix.lower() in (".yml", ".yaml")


class DotnetPathSafety(unittest.TestCase):
    def test_checks_detect_unprotected_examples(self):
        self.assertTrue(python_issues('env = {"DOTNET_CLI_HOME": "fixture"}'))
        self.assertFalse(python_issues('env = {"DOTNET_CLI_HOME": "fixture", "DOTNET_ADD_GLOBAL_TOOLS_TO_PATH": "0"}'))
        self.assertTrue(powershell_issues("$values=@{\n DOTNET_CLI_HOME='fixture'\n}\n"))
        self.assertTrue(workflow_issues('jobs:\n  test:\n    steps:\n      - run: echo DOTNET_CLI_HOME\n'))

    def test_checks_detect_disconnected_environments_and_unprotected_jobs(self):
        self.assertTrue(python_issues('safe = {"DOTNET_CLI_HOME": "unused", "DOTNET_ADD_GLOBAL_TOOLS_TO_PATH": "0"}\n'
                                      'subprocess.run(["dotnet", "build"], env={"USERPROFILE": "temporary"})\n'))
        self.assertTrue(python_issues('subprocess.run(["dotnet", "build"], env={"USERPROFILE": "temporary"})\n'))
        self.assertTrue(python_issues('env = dict(DOTNET_CLI_HOME="temporary")\n'
                                      'subprocess.run(["dotnet", "build"], env=env)\n'))
        self.assertTrue(powershell_issues("$values=@{\n DOTNET_CLI_HOME='safe'\n"
                                         " DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='0'\n}\n"
                                         "$env:DOTNET_CLI_HOME='unprotected'\n& $dotnet build\n"))
        self.assertTrue(workflow_issues("jobs:\n  safe:\n    env:\n"
                                        "      DOTNET_ADD_GLOBAL_TOOLS_TO_PATH: '0'\n"
                                        "    steps:\n      - run: echo safe\n"
                                        "  unsafe:\n    steps:\n      - run: dotnet build\n"))

    def test_checks_accept_protected_launches(self):
        self.assertFalse(python_issues('env = dict(DOTNET_CLI_HOME="fixture", DOTNET_ADD_GLOBAL_TOOLS_TO_PATH="0")\n'
                                       'subprocess.run(["dotnet", "build"], env=env)\n'))
        self.assertFalse(powershell_issues("$env:DOTNET_CLI_HOME='fixture'\n"
                                          "$env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='0'\n& $dotnet build\n"))
        self.assertFalse(workflow_issues("jobs:\n  safe:\n    env:\n"
                                         "      DOTNET_ADD_GLOBAL_TOOLS_TO_PATH: '0'\n"
                                         "    steps:\n      - run: dotnet build\n"))

    def test_checks_detect_aliases_removals_and_step_overrides(self):
        self.assertTrue(python_issues('SDK = Path("dotnet.exe")\n'
                                      'subprocess.run([str(SDK), "build"], env={"HOME": "temporary"})\n'))
        self.assertTrue(python_issues('env = {"DOTNET_CLI_HOME": "fixture", "DOTNET_ADD_GLOBAL_TOOLS_TO_PATH": "0"}\n'
                                      'del env["DOTNET_ADD_GLOBAL_TOOLS_TO_PATH"]\n'
                                      'subprocess.run(["dotnet", "build"], env=env)\n'))
        self.assertTrue(python_issues('env = {"DOTNET_CLI_HOME": "fixture", "DOTNET_ADD_GLOBAL_TOOLS_TO_PATH": "0"}\n'
                                      'env.pop("DOTNET_ADD_GLOBAL_TOOLS_TO_PATH")\n'
                                      'subprocess.run(["dotnet", "build"], env=env)\n'))
        self.assertTrue(powershell_issues("$env:DOTNET_CLI_HOME='fixture'\n"
                                         "$env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='0'\n"
                                         "Remove-Item Env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH\n& $dotnet build\n"))
        self.assertTrue(powershell_issues("$values=@{\n DOTNET_CLI_HOME='fixture'\n"
                                         " DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='0'\n}\n"
                                         "$values.Remove('DOTNET_ADD_GLOBAL_TOOLS_TO_PATH')\nInvoke-Isolated $dotnet\n"))
        self.assertTrue(workflow_issues("jobs:\n  test:\n    env:\n"
                                        "      DOTNET_ADD_GLOBAL_TOOLS_TO_PATH: '0'\n"
                                        "    steps:\n      - run: dotnet build\n        env:\n"
                                        "          DOTNET_ADD_GLOBAL_TOOLS_TO_PATH: '1'\n"))
        self.assertTrue(is_workflow_file(Path("workflow.yaml")))
        self.assertTrue(is_workflow_file(Path("workflow.yml")))

    def test_all_test_runners_and_workflows(self):
        candidates = []
        for base in (ROOT / "windows/native", ROOT / "windows/tests"):
            candidates.extend(path for path in base.rglob("*") if path.suffix.lower() in (".py", ".ps1")
                              and not {"bin", "obj", "__pycache__"}.intersection(path.parts)
                              and path.resolve() != Path(__file__).resolve())
        candidates.extend(path for path in (ROOT / ".github/workflows").iterdir()
                          if path.is_file() and is_workflow_file(path))
        inspected = set()
        for path in candidates:
            source = path.read_text(encoding="utf-8-sig")
            if PROFILE not in source and not re.search(r"\bdotnet(?:\.exe)?\b", source, re.I):
                continue
            inspected.add(path.relative_to(ROOT).as_posix())
            check = python_issues if path.suffix == ".py" else powershell_issues if path.suffix == ".ps1" else workflow_issues
            for issue in check(source):
                with self.subTest(path=str(path.relative_to(ROOT))):
                    self.fail(issue)
        self.assertFalse(REQUIRED_RUNNERS - inspected,
                         "Expected tracked runners were not inspected: " + ", ".join(sorted(REQUIRED_RUNNERS - inspected)))

    def test_nested_dotnet_worker_restores_the_opt_out_after_environment_reset(self):
        source = (ROOT / "windows/native/ClaudeLogWriter/Tests/Program.cs").read_text(encoding="utf-8-sig")
        start = source.index("private static ProcessStartInfo StartInfo(")
        end = source.index("return start;", start)
        fragment = source[start:end]
        reset = fragment.index("start.Environment.Clear();")
        protection = re.search(r'start\.Environment\["' + OPT_OUT + r'"\]\s*=\s*"0";', fragment)
        self.assertIsNotNone(protection)
        self.assertGreater(protection.start(), reset)


if __name__ == "__main__":
    unittest.main()
