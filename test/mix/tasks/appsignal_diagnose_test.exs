defmodule Mix.Tasks.Appsignal.DiagnoseTest do
  use ExUnit.Case
  import ExUnit.CaptureIO
  import AppsignalTest.Utils
  alias Appsignal.{Diagnose.FakeReport, FakeSystem, FakeNif}

  @appsignal_version Mix.Project.config()[:version]
  @agent_version Appsignal.Nif.agent_version()

  defp run, do: capture_io("Y", &run_fn/0)
  defp run(args) when is_list(args), do: capture_io(fn -> run_fn(args) end)
  defp run(input), do: capture_io(input, &run_fn/0)
  defp run_fn(args \\ nil), do: Mix.Tasks.Appsignal.Diagnose.run(args)

  setup do
    environment = freeze_environment()
    Application.delete_env(:appsignal, :config)
    Application.delete_env(:appsignal, :config_sources)

    ExUnit.Callbacks.on_exit(fn ->
      unfreeze_environment(environment)
    end)

    {:ok, fake_report} = FakeReport.start_link()
    {:ok, fake_system} = Appsignal.FakeSystem.start_link()
    {:ok, fake_nif} = Appsignal.FakeNif.start_link()
    # Set loaded? to the actual state of the Nif
    Appsignal.FakeNif.update(fake_nif, :loaded?, Appsignal.Nif.loaded?())

    FakeOS.start_link()

    # By default, Push API key is valid
    auth_bypass = Bypass.open()

    setup_with_config(%{
      active: true,
      valid: true,
      name: "AppSignal test suite app v0",
      env: "test",
      push_api_key: "foo",
      endpoint: "http://localhost:#{auth_bypass.port}"
    })

    Bypass.expect(auth_bypass, fn conn ->
      assert "/1/auth" == conn.request_path
      assert "GET" == conn.method
      Plug.Conn.resp(conn, 200, "")
    end)

    {
      :ok,
      %{
        auth_bypass: auth_bypass,
        fake_report: fake_report,
        fake_system: fake_system,
        fake_nif: fake_nif
      }
    }
  end

  defp received_report(pid) do
    FakeReport.get(pid, :sent_report)
  end

  test "outputs AppSignal support header" do
    output = run()
    assert String.contains?(output, "AppSignal diagnose")
    assert String.contains?(output, "http://docs.appsignal.com/")
    assert String.contains?(output, "support@appsignal.com")
  end

  test "outputs library information" do
    output = run()
    assert String.contains?(output, "AppSignal agent")
    assert String.contains?(output, "Language: Elixir")
    assert String.contains?(output, "Package version: #{@appsignal_version}")
    assert String.contains?(output, "Agent version: #{@agent_version}")
  end

  test "adds library information to report", %{fake_report: fake_report} do
    run()
    report = received_report(fake_report)

    assert report[:library] == %{
             agent_version: @agent_version,
             agent_architecture: Appsignal.System.installed_agent_architecture(),
             extension_loaded: Appsignal.Nif.loaded?(),
             language: "elixir",
             package_version: @appsignal_version
           }
  end

  test "adds process information to report", %{fake_report: fake_report, fake_system: fake_system} do
    run()
    report = received_report(fake_report)
    assert report[:process] == %{uid: FakeSystem.get(fake_system, :uid)}
  end

  @tag :skip_env_test_no_nif
  describe "when Nif is loaded" do
    setup %{fake_nif: fake_nif} do
      FakeNif.update(fake_nif, :loaded?, true)
    end

    test "outputs that the Nif is loaded" do
      output = run()
      assert String.contains?(output, "Nif loaded: yes")
    end

    test "adds library extension_loaded true to report", %{fake_report: fake_report} do
      run()
      report = received_report(fake_report)
      assert report[:library][:extension_loaded] == true
    end
  end

  describe "when Nif is not loaded" do
    setup %{fake_nif: fake_nif} do
      FakeNif.update(fake_nif, :loaded?, false)
    end

    test "outputs that the Nif is not loaded" do
      output = run()
      assert String.contains?(output, "Nif loaded: no")
    end

    test "adds library extension_loaded false to report", %{fake_report: fake_report} do
      run()
      report = received_report(fake_report)
      assert report[:library][:extension_loaded] == false
    end
  end

  test "outputs host information" do
    output = run()
    assert String.contains?(output, "Host information")
    assert String.contains?(output, "Architecture: #{:erlang.system_info(:system_architecture)}")
    assert String.contains?(output, "Elixir version: #{System.version()}")
    assert String.contains?(output, "OTP version: #{System.otp_release()}")
    {_, os} = :os.type()
    assert String.contains?(output, "Operating System: #{os}")
  end

  test "adds host information to report", %{fake_report: fake_report} do
    run()

    report =
      received_report(fake_report)[:host]
      |> Map.drop([:root, :running_in_container])

    {_, os} = :os.type()

    assert report == %{
             architecture: to_string(:erlang.system_info(:system_architecture)),
             language_version: System.version(),
             otp_version: System.otp_release(),
             os: os,
             heroku: false
           }
  end

  describe "when on Heroku" do
    setup %{fake_system: fake_system} do
      FakeSystem.update(fake_system, :heroku, true)
    end

    test "outputs Heroku: yes" do
      output = run()
      assert String.contains?(output, "Heroku: yes")
    end

    test "adds host heroku true to report", %{fake_report: fake_report} do
      run()
      report = received_report(fake_report)
      assert report[:host][:heroku] == true
    end
  end

  describe "when running in a container" do
    setup %{fake_nif: fake_nif} do
      FakeNif.update(fake_nif, :running_in_container?, true)
    end

    test "outputs Container: yes" do
      output = run()
      assert String.contains?(output, "Container: yes")
    end

    test "adds host running_in_container true to report", %{fake_report: fake_report} do
      run()
      report = received_report(fake_report)
      assert report[:host][:running_in_container] == true
    end
  end

  describe "when not running in a container" do
    setup %{fake_nif: fake_nif} do
      FakeNif.update(fake_nif, :running_in_container?, false)
    end

    test "outputs Container: no" do
      output = run()
      assert String.contains?(output, "Container: no")
    end

    test "adds host running_in_container false to report", %{fake_report: fake_report} do
      run()
      report = received_report(fake_report)
      assert report[:host][:running_in_container] == false
    end
  end

  describe "when not root user" do
    test "outputs root user: no" do
      output = run()
      assert String.contains?(output, "root user: no")
    end

    test "adds host root false to report", %{fake_report: fake_report} do
      run()
      report = received_report(fake_report)
      assert report[:host][:root] == false
    end
  end

  describe "when root user" do
    setup %{fake_system: fake_system} do
      FakeSystem.update(fake_system, :root, true)
    end

    test "outputs warning about running as root" do
      output = run()
      assert String.contains?(output, "root user: yes (not recommended)")
    end

    test "adds host root true to report", %{fake_report: fake_report} do
      run()
      report = received_report(fake_report)
      assert report[:host][:root] == true
    end
  end

  @tag :skip_env_test_no_nif
  test "runs agent in diagnose mode", %{fake_nif: fake_nif} do
    FakeNif.update(fake_nif, :run_diagnose, true)
    output = run()
    {:ok, working_directory_stat} = File.stat("/tmp/appsignal")
    assert String.contains?(output, "Agent diagnostics")
    assert String.contains?(output, "  Extension tests\n    Configuration: valid")
    assert String.contains?(output, "  Agent tests")
    assert String.contains?(output, "    Started: started\n    Configuration: valid")
    assert String.contains?(output, "    Process user id: #{process_uid()}")
    assert String.contains?(output, "    Process user group id: #{process_gid()}")
    assert String.contains?(output, "    Logger: started")

    assert String.contains?(
             output,
             "    Working directory user id: #{working_directory_stat.uid}"
           )

    assert String.contains?(
             output,
             "    Working directory user group id: #{working_directory_stat.gid}"
           )

    assert String.contains?(
             output,
             "    Working directory permissions: #{working_directory_stat.mode}"
           )

    assert String.contains?(output, "    Lock path: writable")
  end

  @tag :skip_env_test_no_nif
  test "adds agent report to report", %{fake_report: fake_report, fake_nif: fake_nif} do
    FakeNif.update(fake_nif, :run_diagnose, true)
    run()
    report = received_report(fake_report)
    {:ok, working_directory_stat} = File.stat("/tmp/appsignal")

    assert report[:agent] == %{
             "agent" => %{
               "boot" => %{"started" => %{"result" => true}},
               "host" => %{
                 "uid" => %{"result" => process_uid()},
                 "gid" => %{"result" => process_gid()}
               },
               "config" => %{"valid" => %{"result" => true}},
               "logger" => %{"started" => %{"result" => true}},
               "working_directory_stat" => %{
                 "uid" => %{"result" => working_directory_stat.uid},
                 "gid" => %{"result" => working_directory_stat.gid},
                 "mode" => %{"result" => working_directory_stat.mode}
               },
               "lock_path" => %{"created" => %{"result" => true}}
             },
             "extension" => %{
               "config" => %{"valid" => %{"result" => true}}
             }
           }
  end

  describe "when config is not active" do
    @tag :skip_env_test_no_nif
    test "runs agent in diagnose mode, but doesn't change the active state", %{fake_nif: fake_nif} do
      FakeNif.update(fake_nif, :run_diagnose, true)

      output = with_config(%{active: false}, &run/0)
      {:ok, working_directory_stat} = File.stat("/tmp/appsignal")
      assert String.contains?(output, "active: false")
      assert String.contains?(output, "Agent diagnostics")
      assert String.contains?(output, "  Extension tests\n    Configuration: valid")
      assert String.contains?(output, "  Agent tests")
      assert String.contains?(output, "    Started: started\n    Configuration: valid")
      assert String.contains?(output, "    Process user id: #{process_uid()}")
      assert String.contains?(output, "    Process user group id: #{process_gid()}")
      assert String.contains?(output, "    Logger: started")

      assert String.contains?(
               output,
               "    Working directory user id: #{working_directory_stat.uid}"
             )

      assert String.contains?(
               output,
               "    Working directory user group id: #{working_directory_stat.gid}"
             )

      assert String.contains?(
               output,
               "    Working directory permissions: #{working_directory_stat.mode}"
             )

      assert String.contains?(output, "    Lock path: writable")
    end

    @tag :skip_env_test_no_nif
    test "adds agent report to report", %{fake_report: fake_report, fake_nif: fake_nif} do
      FakeNif.update(fake_nif, :run_diagnose, true)
      run()
      report = received_report(fake_report)
      {:ok, working_directory_stat} = File.stat("/tmp/appsignal")

      assert report[:agent] == %{
               "agent" => %{
                 "boot" => %{"started" => %{"result" => true}},
                 "host" => %{
                   "uid" => %{"result" => process_uid()},
                   "gid" => %{"result" => process_gid()}
                 },
                 "config" => %{"valid" => %{"result" => true}},
                 "logger" => %{"started" => %{"result" => true}},
                 "working_directory_stat" => %{
                   "uid" => %{"result" => working_directory_stat.uid},
                   "gid" => %{"result" => working_directory_stat.gid},
                   "mode" => %{"result" => working_directory_stat.mode}
                 },
                 "lock_path" => %{"created" => %{"result" => true}}
               },
               "extension" => %{
                 "config" => %{"valid" => %{"result" => true}}
               }
             }
    end
  end

  describe "when extension is not loaded" do
    setup %{fake_nif: fake_nif} do
      FakeNif.update(fake_nif, :loaded?, false)
    end

    test "agent diagnostics is not run" do
      output = run()
      assert String.contains?(output, "Agent diagnostics")
      assert String.contains?(output, "  Error: Nif not loaded, aborting.")
    end

    test "adds no agent report to report", %{fake_report: fake_report} do
      run()
      assert received_report(fake_report)[:agent] == nil
    end
  end

  describe "when extension output is invalid JSON" do
    setup %{fake_nif: fake_nif} do
      FakeNif.update(fake_nif, :loaded?, true)
      FakeNif.update(fake_nif, :diagnose, "agent_report_string")
    end

    test "agent diagnostics report prints an error" do
      output = run()
      assert String.contains?(output, "Agent diagnostics")
      assert String.contains?(output, "  Error: Could not parse the agent report:")
      assert String.contains?(output, "    Output: agent_report_string")
    end

    test "adds agent output to report", %{fake_report: fake_report} do
      run()
      report = received_report(fake_report)
      assert report[:agent] == %{output: "agent_report_string"}
    end
  end

  describe "when extension output is missing a test" do
    setup %{fake_nif: fake_nif} do
      FakeNif.update(fake_nif, :loaded?, true)
      FakeNif.update(fake_nif, :diagnose, ~s(
        {
          "extension": { "config": { "valid": { "result": true } } }
        }
      ))
    end

    test "agent diagnostics report prints the tests, but shows a dash `-` for missed results" do
      output = run()
      assert String.contains?(output, "Agent diagnostics")
      assert String.contains?(output, "  Extension tests\n    Configuration: valid")
      assert String.contains?(output, "  Agent tests")
      assert String.contains?(output, "    Started: -")
      assert String.contains?(output, "    Configuration: -")
      assert String.contains?(output, "    Process user id: -")
      assert String.contains?(output, "    Process user group id: -")
      assert String.contains?(output, "    Lock path: -")
      assert String.contains?(output, "    Logger: -")
      assert String.contains?(output, "    Working directory user id: -")
      assert String.contains?(output, "    Working directory user group id: -")
      assert String.contains?(output, "    Working directory permissions: -")
    end

    test "missings tests are not added to report", %{fake_report: fake_report} do
      run()

      assert received_report(fake_report)[:agent] == %{
               "extension" => %{
                 "config" => %{"valid" => %{"result" => true}}
               }
               # Missing agent report
             }
    end
  end

  describe "when the agent diagnose report contains an error" do
    setup %{fake_nif: fake_nif} do
      FakeNif.update(fake_nif, :loaded?, true)
      FakeNif.update(fake_nif, :diagnose, ~s({ "error": "fatal error" }))
    end

    test "prints the error" do
      output = run()
      assert String.contains?(output, "Agent diagnostics\n  Error: fatal error")
    end

    test "adds the error to the report", %{fake_report: fake_report} do
      run()
      assert received_report(fake_report)[:agent] == %{"error" => "fatal error"}
    end
  end

  describe "when an agent diagnose report test contains an error" do
    setup %{fake_nif: fake_nif} do
      FakeNif.update(fake_nif, :loaded?, true)
      FakeNif.update(fake_nif, :diagnose, ~s(
        {
          "agent": { "boot": { "started": { "result": false, "error": "my error" } } }
        }
      ))
    end

    test "prints the error" do
      output = run()
      assert String.contains?(output, "Agent diagnostics")
      assert String.contains?(output, "  Started: not started\n      Error: my error")
    end
  end

  describe "when an agent diagnose report test contains command output" do
    setup %{fake_nif: fake_nif} do
      FakeNif.update(fake_nif, :loaded?, true)
      FakeNif.update(fake_nif, :diagnose, ~s(
        {
          "agent": { "boot": { "started": { "result": false, "output": "my output" } } }
        }
      ))
    end

    test "prints the output" do
      output = run()
      assert String.contains?(output, "Agent diagnostics")
      assert String.contains?(output, "  Started: not started\n      Output: my output")
    end
  end

  describe "configuration" do
    test "outputs inspected configuration option values" do
      output = run()
      assert String.contains?(output, "Configuration")

      config = Application.get_env(:appsignal, :config)

      refute Enum.empty?(config)

      Enum.each(config, fn {key, value} ->
        assert String.contains?(output, "  #{key}: #{inspect(value)}")
      end)
    end

    test "outputs no source for option when only default source" do
      output = run()

      assert String.contains?(output, "  send_params: true\n")
    end

    test "outputs the source when there is only one source (not default)" do
      output = run()

      assert String.contains?(
               output,
               "  name: \"AppSignal test suite app v0\" (Loaded from file)\n"
             )
    end

    test "outputs sources for option with multiple sources" do
      output = run()

      assert String.contains?(
               output,
               "  active: true\n    Sources:\n      default: false\n      file:    true"
             )
    end

    test "outputs all different sources for option when available" do
      output =
        with_env(
          %{"DYNO" => "true", "APPSIGNAL_PUSH_API_KEY" => "bar"},
          fn ->
            with_config(%{running_in_container: false}, &run/0)
          end
        )

      assert String.contains?(
               output,
               "  push_api_key: \"bar\"\n    Sources:\n      file: \"foo\"\n      env:  \"bar\""
             )

      assert String.contains?(
               output,
               "  running_in_container: false\n    Sources:\n      system: true\n      file:   false"
             )
    end
  end

  test "adds configuration to the report", %{fake_report: fake_report} do
    run()

    assert received_report(fake_report)[:config] == %{
             options: Application.get_env(:appsignal, :config),
             sources: Application.get_env(:appsignal, :config_sources)
           }
  end

  describe "with valid Push API key" do
    test "outputs invalid API key warning" do
      output = run()
      assert String.contains?(output, "Validation")
      assert String.contains?(output, "Push API key: valid")
    end

    test "adds validation to the report", %{fake_report: fake_report} do
      run()
      assert received_report(fake_report)[:validation] == %{push_api_key: "valid"}
    end
  end

  describe "with invalid Push API key" do
    setup %{auth_bypass: auth_bypass} do
      setup_with_config(%{push_api_key: ""})

      Bypass.expect(auth_bypass, fn conn ->
        assert "/1/auth" == conn.request_path
        assert "GET" == conn.method
        Plug.Conn.resp(conn, 401, "")
      end)
    end

    test "outputs invalid API key warning" do
      output = run()
      assert String.contains?(output, "Validation")
      assert String.contains?(output, "Push API key: invalid")
    end

    test "adds validation to the report", %{fake_report: fake_report} do
      run()
      assert received_report(fake_report)[:validation] == %{push_api_key: "invalid"}
    end
  end

  describe "when install.log exists" do
    setup do
      content =
        "[2017-11-10 13:39:47.795755Z] Error!\n[2017-11-10 13:39:48.795755Z] Another Error!"

      File.write!(install_log_path(), content)

      {:ok, %{content: content}}
    end

    test "outputs the log file", %{content: content} do
      output = run()
      assert String.contains?(output, "Extension install log")
      assert String.contains?(output, "Path: #{inspect(install_log_path())}")
      assert String.contains?(output, content)
    end

    test "adds log file to report", %{content: content, fake_report: fake_report} do
      run()
      path = install_log_path()
      {:ok, %{mode: mode, uid: uid, gid: gid}} = File.stat(path)
      paths = received_report(fake_report)[:paths]

      assert paths[:"install.log"] == %{
               path: path,
               exists: true,
               type: :file,
               mode: mode,
               writable: true,
               ownership: %{uid: uid, gid: gid},
               content: content |> String.split("\n")
             }
    end
  end

  describe "when install.log does not exist" do
    setup do
      File.rm(install_log_path())
      :ok
    end

    test "outputs the log" do
      output = run()
      assert String.contains?(output, "Path: #{inspect(install_log_path())}\n    Exists?: no")
    end

    test "adds log file to report", %{fake_report: fake_report} do
      run()
      paths = received_report(fake_report)[:paths]

      assert paths[:"install.log"] == %{
               path: install_log_path(),
               exists: false
             }
    end
  end

  describe "without config" do
    test "it outputs tmp dir for log_dir_path" do
      output = with_config(%{log_path: nil}, &run/0)
      assert String.contains?(output, "Log directory\n    Path: \"/tmp\"")
      assert String.contains?(output, "AppSignal log\n    Path: \"/tmp/appsignal.log\"")
    end

    test "adds paths to report", %{fake_report: fake_report} do
      run()

      assert Map.keys(received_report(fake_report)[:paths]) == [
               :"appsignal.log",
               :"install.log",
               :log_dir_path,
               :working_dir
             ]
    end
  end

  describe "when log_dir_path is writable" do
    setup do
      %{log_dir_path: log_dir_path, "appsignal.log": log_file_path} =
        prepare_tmp_dir("writable_path")

      {:ok, %{log_dir_path: log_dir_path, "appsignal.log": log_file_path}}
    end

    @tag :skip_env_test_no_nif
    test "outputs writable and creates log file", %{
      log_dir_path: log_dir_path,
      "appsignal.log": log_file_path,
      fake_nif: fake_nif
    } do
      FakeNif.update(fake_nif, :run_diagnose, true)
      output = run()

      assert String.contains?(
               output,
               "Log directory\n    Path: #{inspect(log_dir_path)}\n    Writable?: yes"
             )

      assert String.contains?(
               output,
               "AppSignal log\n    Path: #{inspect(log_file_path)}\n    Writable?: yes"
             )
    end

    @tag :skip_env_test_no_nif
    test "adds writable log paths to report", %{
      log_dir_path: log_dir_path,
      "appsignal.log": log_file_path,
      fake_report: fake_report,
      fake_nif: fake_nif
    } do
      FakeNif.update(fake_nif, :run_diagnose, true)
      run()
      paths = received_report(fake_report)[:paths]

      %{mode: mode, uid: uid, gid: gid} = File.stat!(log_dir_path)

      assert paths[:log_dir_path] == %{
               type: :directory,
               path: log_dir_path,
               exists: true,
               mode: mode,
               writable: true,
               ownership: %{uid: uid, gid: gid}
             }

      %{mode: mode, uid: uid, gid: gid} = File.stat!(log_file_path)

      assert paths[:"appsignal.log"] == %{
               type: :file,
               path: log_file_path,
               exists: true,
               mode: mode,
               writable: true,
               ownership: %{uid: uid, gid: gid},
               content: ["log line 1", "log line 2", "log line 3"]
             }
    end
  end

  describe "when path is owned by current user" do
    setup do
      %{log_dir_path: log_dir_path} = prepare_tmp_dir("not_owned_path")
      %{uid: uid} = File.stat!(log_dir_path)

      {:ok, %{log_dir_path: log_dir_path, uid: uid}}
    end

    test "outputs ownership uid", %{
      log_dir_path: log_dir_path,
      uid: uid,
      fake_system: fake_system
    } do
      FakeSystem.update(fake_system, :uid, uid)
      output = run()

      assert String.contains?(
               output,
               "Log directory\n    Path: \"#{log_dir_path}\"\n    Writable?: yes\n" <>
                 "    Ownership?: yes (file: #{uid}, process: #{FakeSystem.get(fake_system, :uid)})"
             )
    end
  end

  describe "when path is not owned by current user" do
    setup do
      %{log_dir_path: log_dir_path} = prepare_tmp_dir("owned_path")

      {:ok, %{log_dir_path: log_dir_path}}
    end

    test "outputs ownership uid", %{log_dir_path: log_dir_path, fake_system: fake_system} do
      %{uid: uid} = File.stat!(log_dir_path)
      output = run()

      assert String.contains?(
               output,
               "Log directory\n    Path: \"#{log_dir_path}\"\n    Writable?: yes\n" <>
                 "    Ownership?: no (file: #{uid}, process: #{FakeSystem.get(fake_system, :uid)})"
             )
    end
  end

  describe "when user does not submit report to AppSignal" do
    test "does not send the report", %{fake_report: fake_report} do
      output = run("n")
      assert String.contains?(output, "Diagnostics report")
      assert String.contains?(output, "Send diagnostics report to AppSignal? (Y/n):")
      assert String.contains?(output, "Not sending diagnostics report to AppSignal.")

      refute FakeReport.get(fake_report, :report_sent?)
    end
  end

  describe "when user submits report to AppSignal" do
    test "sends diagnostics report to AppSignal and outputs a support token", %{
      fake_report: fake_report
    } do
      token = "0123456789abcdef"
      assert FakeReport.update(fake_report, :response, {:ok, token})
      output = run()
      assert String.contains?(output, "Diagnostics report")
      assert String.contains?(output, "Send diagnostics report to AppSignal? (Y/n):")
      assert String.contains?(output, "Transmitting diagnostics report")
      assert String.contains?(output, "Your support token: #{token}")

      assert String.contains?(
               output,
               "View this report:   https://appsignal.com/diagnose/#{token}"
             )

      assert FakeReport.get(fake_report, :report_sent?)
      assert received_report(fake_report)
    end

    test "when returns invalid output it outputs an error", %{fake_report: fake_report} do
      assert FakeReport.update(fake_report, :response, {:error, %{status_code: 200, body: "foo"}})
      output = run()
      assert String.contains?(output, "Diagnostics report")
      assert String.contains?(output, "Send diagnostics report to AppSignal? (Y/n):")
      assert String.contains?(output, "Transmitting diagnostics report")
      assert String.contains?(output, "Error: Couldn't decode server response.")
      assert String.contains?(output, "Response body: foo")
    end

    test "when server errors it outputs an error", %{fake_report: fake_report} do
      assert FakeReport.update(fake_report, :response, {:error, %{status_code: 500, body: "foo"}})
      output = run()
      assert String.contains?(output, "Diagnostics report")
      assert String.contains?(output, "Send diagnostics report to AppSignal? (Y/n):")
      assert String.contains?(output, "Transmitting diagnostics report")

      assert String.contains?(
               output,
               "Error: Something went wrong while submitting the report to AppSignal."
             )

      assert String.contains?(output, "Response code: 500")
      assert String.contains?(output, "Response body: foo")
    end

    test "when no connection to server it outputs an error", %{fake_report: fake_report} do
      assert FakeReport.update(fake_report, :response, {:error, %{reason: "foo"}})
      output = run()
      assert String.contains?(output, "Diagnostics report")
      assert String.contains?(output, "Send diagnostics report to AppSignal? (Y/n):")
      assert String.contains?(output, "Transmitting diagnostics report")

      assert String.contains?(
               output,
               "Error: Something went wrong while submitting the report to AppSignal.\nfoo"
             )
    end
  end

  describe "when user uses the --no-send-report option" do
    test "does not send the report", %{fake_report: fake_report} do
      assert FakeReport.update(fake_report, :response, {:ok, "0123456789abcdef"})
      output = run(["--no-send-report"])
      assert String.contains?(output, "Diagnostics report")

      assert String.contains?(
               output,
               "Not sending report. (Specified with the --no-send-report option.)"
             )

      assert String.contains?(output, "Not sending diagnostics report to AppSignal.")

      refute FakeReport.get(fake_report, :report_sent?)
    end
  end

  describe "when user uses the --send-report option" do
    test "sends diagnostics report to AppSignal and outputs a support token", %{
      fake_report: fake_report
    } do
      token = "0123456789abcdef"
      assert FakeReport.update(fake_report, :response, {:ok, token})
      output = run(["--send-report"])
      assert String.contains?(output, "Diagnostics report")
      assert String.contains?(output, "Confirmed sending report using --send-report option.")
      assert String.contains?(output, "Transmitting diagnostics report")
      assert String.contains?(output, "Your support token: #{token}")

      assert String.contains?(
               output,
               "View this report:   https://appsignal.com/diagnose/#{token}"
             )

      assert FakeReport.get(fake_report, :report_sent?)
      assert received_report(fake_report)
    end
  end

  defp prepare_tmp_dir(path) do
    log_dir_path = Path.expand("tmp/#{path}", File.cwd!())
    log_file_path = Path.expand("appsignal.log", log_dir_path)

    on_exit(:clean_up, fn ->
      File.rm_rf!(log_dir_path)
    end)

    File.mkdir_p!(log_dir_path)
    setup_with_config(%{log_path: log_dir_path})
    File.write!(log_file_path, "log line 1\nlog line 2\nlog line 3")

    %{log_dir_path: log_dir_path, "appsignal.log": log_file_path}
  end

  def install_log_path() do
    :appsignal
    |> Application.app_dir()
    |> Path.join("install.log")
  end

  defp process_uid() do
    case System.cmd("id", ["-u"]) do
      {id, 0} ->
        case Integer.parse(List.first(String.split(id, "\n"))) do
          {int, _} -> int
          :error -> nil
        end

      {_, _} ->
        nil
    end
  end

  defp process_gid() do
    case System.cmd("id", ["-g"]) do
      {id, 0} ->
        case Integer.parse(List.first(String.split(id, "\n"))) do
          {int, _} -> int
          :error -> nil
        end

      {_, _} ->
        nil
    end
  end
end
