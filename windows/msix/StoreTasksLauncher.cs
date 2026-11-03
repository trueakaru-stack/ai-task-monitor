using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Management.Automation;
using System.Management.Automation.Language;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Threading;

internal static class StoreTasksLauncher
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            string directory = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(directory, "CodexProgress.ps1");
            Assembly.LoadFrom(Path.Combine(directory, "AITaskMonitor.Runtime.dll"));
            Environment.SetEnvironmentVariable("PSExecutionPolicyPreference", "Bypass", EnvironmentVariableTarget.Process);

            Token[] tokens;
            ParseError[] errors;
            ScriptBlockAst ast = Parser.ParseFile(script, out tokens, out errors);
            if (errors.Length != 0 || ast.ParamBlock == null) throw new InvalidOperationException("Invalid monitor script parameters.");
            var parameters = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
            foreach (ParameterAst parameter in ast.ParamBlock.Parameters)
                parameters.Add(parameter.Name.VariablePath.UserPath, parameter.StaticType == typeof(SwitchParameter));

            using (Runspace runspace = RunspaceFactory.CreateRunspace(InitialSessionState.CreateDefault()))
            {
                runspace.ApartmentState = ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();
                using (PowerShell shell = PowerShell.Create())
                {
                    shell.Runspace = runspace;
                    shell.AddCommand(script);
                    for (int i = 0; i < args.Length; i++)
                    {
                        string argument = args[i];
                        if (argument.Length < 2 || argument[0] != '-') throw new ArgumentException("Expected a named monitor argument.");
                        string name = argument.Substring(1);
                        bool isSwitch;
                        if (!parameters.TryGetValue(name, out isSwitch)) throw new ArgumentException("Unknown monitor argument: " + name);
                        if (isSwitch) shell.AddParameter(name);
                        else
                        {
                            if (++i >= args.Length) throw new ArgumentException("Missing value for monitor argument: " + name);
                            shell.AddParameter(name, args[i]);
                        }
                    }
                    shell.Invoke();
                    // Handled PowerShell errors can set HadErrors even when the error stream is empty.
                    if (shell.Streams.Error.Count != 0)
                    {
                        foreach (ErrorRecord error in shell.Streams.Error) Console.Error.WriteLine(error.ToString());
                        return 1;
                    }
                }
            }
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error.ToString());
            return 1;
        }
    }
}
