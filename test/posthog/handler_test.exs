defmodule PostHog.HandlerTest do
  use PostHog.Case, async: true

  require Logger

  @moduletag capture_log: true

  setup_all {LoggerHandlerKit.Arrange, :ensure_per_handler_translation}
  setup :setup_supervisor
  setup :setup_logger_handler

  test "takes distinct_id from metadata", %{
    handler_ref: ref,
    config: %{supervisor_name: supervisor_name}
  } do
    Logger.info("Hello World", distinct_id: "foo")
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    assert %{
             event: "$exception",
             uuid: _,
             distinct_id: "foo",
             properties: %{
               "$exception_list": [
                 %{
                   type: "Hello World",
                   value: "Hello World",
                   mechanism: %{handled: true, type: "generic"}
                 }
               ]
             }
           } = event
  end

  @tag config: [global_properties: %{foo: "bar"}]
  test "always exports global context", %{
    handler_ref: ref,
    config: %{supervisor_name: supervisor_name}
  } do
    Logger.info("Hello World")
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    assert %{
             event: "$exception",
             uuid: _,
             properties: %{
               "$lib": "posthog-elixir",
               "$lib_version": _,
               foo: "bar",
               "$exception_list": [
                 %{
                   type: "Hello World",
                   value: "Hello World",
                   mechanism: %{handled: true, type: "generic"}
                 }
               ]
             }
           } = event
  end

  @tag config: [capture_level: :warning]
  test "ignores messages lower than capture_level", %{
    handler_ref: ref,
    config: %{supervisor_name: supervisor_name}
  } do
    Logger.info("Hello World")
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [] = all_captured(supervisor_name)
  end

  @tag config: [capture_level: :warning]
  test "logs with crash reason always captured", %{
    handler_ref: ref,
    config: %{supervisor_name: supervisor_name}
  } do
    Logger.debug("Hello World", crash_reason: {"exit reason", []})
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    if pre_19?() do
      assert %{
               event: "$exception",
               uuid: _,
               properties: %{
                 "$exception_list": [
                   %{
                     type: "** (exit) \"exit reason\"",
                     value: "** (exit) \"exit reason\"",
                     mechanism: %{handled: false, type: "generic"}
                   }
                 ]
               }
             } = event
    else
      assert %{
               event: "$exception",
               uuid: _,
               properties: %{
                 "$exception_list": [
                   %{
                     mechanism: %{handled: true, type: "generic"},
                     type: "Hello World",
                     value: "Hello World"
                   },
                   %{
                     type: "** (exit) \"exit reason\"",
                     value: "** (exit) \"exit reason\"",
                     mechanism: %{handled: false, type: "generic"}
                   }
                 ]
               }
             } = event
    end
  end

  test "string message", %{handler_ref: ref, config: %{supervisor_name: supervisor_name}} do
    LoggerHandlerKit.Act.string_message()
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    assert %{
             event: "$exception",
             uuid: _,
             properties: %{
               "$exception_list": [
                 %{
                   type: "Hello World",
                   value: "Hello World",
                   mechanism: %{handled: true}
                 }
               ]
             }
           } = event
  end

  test "charlist message", %{handler_ref: ref, config: %{supervisor_name: supervisor_name}} do
    LoggerHandlerKit.Act.charlist_message()
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    assert %{
             event: "$exception",
             uuid: _,
             properties: %{
               "$exception_list": [
                 %{
                   type: "Hello World",
                   value: "Hello World",
                   mechanism: %{handled: true}
                 }
               ]
             }
           } = event
  end

  test "chardata message", %{handler_ref: ref, config: %{supervisor_name: supervisor_name}} do
    LoggerHandlerKit.Act.chardata_message(:proper)
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    assert %{
             event: "$exception",
             uuid: _,
             properties: %{
               "$exception_list": [
                 %{
                   type: "Hello World",
                   value: "Hello World",
                   mechanism: %{handled: true}
                 }
               ]
             }
           } = event
  end

  test "chardata message - emoji", %{
    handler_ref: ref,
    config: %{supervisor_name: supervisor_name}
  } do
    Logger.bare_log(:info, [?H, ["ello", []], 32, ~c"World 🪩"])
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    assert %{
             event: "$exception",
             properties: %{
               "$exception_list": [
                 %{
                   type: "Hello World 🪩",
                   value: "Hello World 🪩",
                   mechanism: %{handled: true}
                 }
               ]
             }
           } = event
  end

  test "chardata message - improper", %{
    handler_ref: ref,
    config: %{supervisor_name: supervisor_name}
  } do
    LoggerHandlerKit.Act.chardata_message(:improper)
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    assert %{
             event: "$exception",
             uuid: _,
             properties: %{
               "$exception_list": [
                 %{
                   type: "Hello World",
                   value: "Hello World",
                   mechanism: %{handled: true}
                 }
               ]
             }
           } = event
  end

  test "io format", %{handler_ref: ref, config: %{supervisor_name: supervisor_name}} do
    LoggerHandlerKit.Act.io_format()
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    assert %{
             event: "$exception",
             uuid: _,
             properties: %{
               "$exception_list": [
                 %{
                   type: "Hello World",
                   value: "Hello World",
                   mechanism: %{handled: true}
                 }
               ]
             }
           } = event
  end

  test "keyword report", %{handler_ref: ref, config: %{supervisor_name: supervisor_name}} do
    LoggerHandlerKit.Act.keyword_report()
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    assert %{
             event: "$exception",
             uuid: _,
             properties: %{
               "$exception_list": [
                 %{
                   type: "[hello: \"world\"]",
                   value: "[hello: \"world\"]",
                   mechanism: %{handled: true}
                 }
               ]
             }
           } = event
  end

  test "map report", %{handler_ref: ref, config: %{supervisor_name: supervisor_name}} do
    LoggerHandlerKit.Act.map_report()
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    assert %{
             event: "$exception",
             uuid: _,
             properties: %{
               "$exception_list": [
                 %{
                   type: "%{hello: \"world\"}",
                   value: "%{hello: \"world\"}",
                   mechanism: %{handled: true}
                 }
               ]
             }
           } = event
  end

  test "struct report", %{handler_ref: ref, config: %{supervisor_name: supervisor_name}} do
    LoggerHandlerKit.Act.struct_report()
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    assert %{
             event: "$exception",
             properties: %{
               "$exception_list": [
                 %{
                   type: "%LoggerHandlerKit.FakeStruct{hello: \"world\"}",
                   value: "%LoggerHandlerKit.FakeStruct{hello: \"world\"}",
                   mechanism: %{handled: true}
                 }
               ]
             }
           } = event
  end

  test "task error exception", %{handler_ref: ref, config: %{supervisor_name: supervisor_name}} do
    LoggerHandlerKit.Act.task_error(:exception)
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    if pre_19?() do
      assert %{
               event: "$exception",
               properties: %{
                 "$exception_list": [
                   %{
                     type: "RuntimeError",
                     value: "** (RuntimeError) oops",
                     mechanism: %{handled: false, type: "generic"},
                     stacktrace: %{
                       type: "raw",
                       frames: [
                         %{
                           in_app: false,
                           filename: "lib/logger_handler_kit/act.ex",
                           function: "anonymous fn/0 in LoggerHandlerKit.Act.task_error/1",
                           lineno: _,
                           module: "LoggerHandlerKit.Act",
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           in_app: false,
                           filename: "lib/task/supervised.ex",
                           function: "Task.Supervised.invoke_mfa/2",
                           lineno: _,
                           module: "Task.Supervised",
                           platform: "custom",
                           lang: "elixir"
                         }
                       ]
                     }
                   }
                 ]
               }
             } = event
    else
      assert %{
               event: "$exception",
               properties: %{
                 task_process_label: :undefined,
                 task_starter: "#PID<" <> _,
                 task_name: "#PID<" <> _,
                 "$exception_list": [
                   %{
                     type: "RuntimeError",
                     value: "** (RuntimeError) oops",
                     mechanism: %{handled: false, type: "generic"},
                     stacktrace: %{
                       type: "raw",
                       frames: [
                         %{
                           in_app: false,
                           filename: "lib/logger_handler_kit/act.ex",
                           function: "anonymous fn/0 in LoggerHandlerKit.Act.task_error/1",
                           lineno: _,
                           module: "LoggerHandlerKit.Act",
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           in_app: false,
                           filename: "lib/task/supervised.ex",
                           function: "Task.Supervised.invoke_mfa/2",
                           lineno: _,
                           module: "Task.Supervised",
                           platform: "custom",
                           lang: "elixir"
                         }
                       ]
                     }
                   },
                   %{
                     mechanism: %{handled: true, type: "generic"},
                     type: "Task terminating",
                     value: "Task" <> _
                   }
                 ]
               }
             } = event
    end
  end

  test "task error throw", %{handler_ref: ref, config: %{supervisor_name: supervisor_name}} do
    LoggerHandlerKit.Act.task_error(:throw)
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    if pre_19?() do
      assert %{
               event: "$exception",
               properties: %{
                 "$exception_list": [
                   %{
                     type: "** (throw) \"catch!\"",
                     value: "** (throw) \"catch!\"",
                     mechanism: %{handled: false, type: "generic"},
                     stacktrace: %{
                       type: "raw",
                       frames: [
                         %{
                           in_app: false,
                           filename: "lib/logger_handler_kit/act.ex",
                           function: "anonymous fn/0 in LoggerHandlerKit.Act.task_error/1",
                           lineno: _,
                           module: "LoggerHandlerKit.Act",
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           in_app: false,
                           filename: "lib/task/supervised.ex",
                           function: "Task.Supervised.invoke_mfa/2",
                           lineno: _,
                           module: "Task.Supervised",
                           platform: "custom",
                           lang: "elixir"
                         }
                       ]
                     }
                   }
                 ]
               }
             } = event
    else
      assert %{
               event: "$exception",
               properties: %{
                 task_process_label: :undefined,
                 task_starter: "#PID<" <> _,
                 task_name: "#PID<" <> _,
                 "$exception_list": [
                   %{
                     type: "** (throw) \"catch!\"",
                     value: "** (throw) \"catch!\"",
                     mechanism: %{handled: false, type: "generic"},
                     stacktrace: %{
                       type: "raw",
                       frames: [
                         %{
                           in_app: false,
                           filename: "lib/logger_handler_kit/act.ex",
                           function: "anonymous fn/0 in LoggerHandlerKit.Act.task_error/1",
                           lineno: _,
                           module: "LoggerHandlerKit.Act",
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           in_app: false,
                           filename: "lib/task/supervised.ex",
                           function: "Task.Supervised.invoke_mfa/2",
                           lineno: _,
                           module: "Task.Supervised",
                           platform: "custom",
                           lang: "elixir"
                         }
                       ]
                     }
                   },
                   %{
                     mechanism: %{handled: true, type: "generic"},
                     type: "Task terminating",
                     value: "Task" <> _
                   }
                 ]
               }
             } = event
    end
  end

  test "task error exit", %{handler_ref: ref, config: %{supervisor_name: supervisor_name}} do
    LoggerHandlerKit.Act.task_error(:exit)
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    if pre_19?() do
      assert %{
               event: "$exception",
               properties: %{
                 "$exception_list": [
                   %{
                     type: "** (exit) \"i quit\"",
                     value: "** (exit) \"i quit\"",
                     mechanism: %{handled: false, type: "generic"},
                     stacktrace: %{
                       type: "raw",
                       frames: [
                         %{
                           in_app: false,
                           filename: "lib/logger_handler_kit/act.ex",
                           function: "anonymous fn/0 in LoggerHandlerKit.Act.task_error/1",
                           lineno: _,
                           module: "LoggerHandlerKit.Act",
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           in_app: false,
                           filename: "lib/task/supervised.ex",
                           function: "Task.Supervised.invoke_mfa/2",
                           lineno: _,
                           module: "Task.Supervised",
                           platform: "custom",
                           lang: "elixir"
                         }
                       ]
                     }
                   }
                 ]
               }
             } = event
    else
      assert %{
               event: "$exception",
               properties: %{
                 task_process_label: :undefined,
                 task_starter: "#PID<" <> _,
                 task_name: "#PID<" <> _,
                 "$exception_list": [
                   %{
                     type: "** (exit) \"i quit\"",
                     value: "** (exit) \"i quit\"",
                     mechanism: %{handled: false, type: "generic"},
                     stacktrace: %{
                       type: "raw",
                       frames: [
                         %{
                           in_app: false,
                           filename: "lib/logger_handler_kit/act.ex",
                           function: "anonymous fn/0 in LoggerHandlerKit.Act.task_error/1",
                           lineno: _,
                           module: "LoggerHandlerKit.Act",
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           in_app: false,
                           filename: "lib/task/supervised.ex",
                           function: "Task.Supervised.invoke_mfa/2",
                           lineno: _,
                           module: "Task.Supervised",
                           platform: "custom",
                           lang: "elixir"
                         }
                       ]
                     }
                   },
                   %{
                     mechanism: %{handled: true, type: "generic"},
                     type: "Task terminating",
                     value: "Task" <> _
                   }
                 ]
               }
             } = event
    end
  end

  test "genserver crash exception", %{
    handler_ref: ref,
    config: %{supervisor_name: supervisor_name}
  } do
    LoggerHandlerKit.Act.genserver_crash(:exception)
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    if pre_19?() do
      assert %{
               event: "$exception",
               properties: %{
                 "$exception_list": [
                   %{
                     type: "RuntimeError",
                     value: "** (RuntimeError) oops",
                     mechanism: %{handled: false, type: "generic"},
                     stacktrace: %{
                       type: "raw",
                       frames: [
                         %{
                           in_app: false,
                           filename: "lib/logger_handler_kit/act.ex",
                           function: "anonymous fn/0 in LoggerHandlerKit.Act.genserver_crash/1",
                           lineno: _,
                           module: "LoggerHandlerKit.Act",
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           filename: "gen_server.erl",
                           function: ":gen_server.try_handle_call/4",
                           in_app: false,
                           lineno: _,
                           module: ":gen_server",
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           filename: "gen_server.erl",
                           function: ":gen_server.handle_msg" <> _,
                           in_app: false,
                           lineno: _,
                           module: ":gen_server",
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           filename: "proc_lib.erl",
                           function: ":proc_lib.init_p_do_apply/3",
                           in_app: false,
                           lineno: _,
                           module: ":proc_lib",
                           platform: "custom",
                           lang: "elixir"
                         }
                       ]
                     }
                   }
                 ]
               }
             } = event
    else
      assert %{
               event: "$exception",
               properties: %{
                 genserver_name: "#PID<" <> _,
                 genserver_state: nil,
                 genserver_last_message: [:run, _fun_name],
                 genserver_process_label: :undefined,
                 genserver_client: "#PID<" <> _,
                 "$exception_list": [
                   %{
                     type: "RuntimeError",
                     value: "** (RuntimeError) oops",
                     mechanism: %{handled: false, type: "generic"},
                     stacktrace: %{
                       type: "raw",
                       frames: [
                         %{
                           in_app: false,
                           filename: "lib/logger_handler_kit/act.ex",
                           function: "anonymous fn/0 in LoggerHandlerKit.Act.genserver_crash/1",
                           lineno: _,
                           module: "LoggerHandlerKit.Act",
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           filename: "gen_server.erl",
                           function: ":gen_server.try_handle_call/4",
                           in_app: false,
                           lineno: _,
                           module: ":gen_server",
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           filename: "gen_server.erl",
                           function: ":gen_server.handle_msg" <> _,
                           in_app: false,
                           lineno: _,
                           module: ":gen_server",
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           filename: "proc_lib.erl",
                           function: ":proc_lib.init_p_do_apply/3",
                           in_app: false,
                           lineno: _,
                           module: ":proc_lib",
                           platform: "custom",
                           lang: "elixir"
                         }
                       ]
                     }
                   },
                   %{
                     mechanism: %{handled: true, type: "generic"},
                     type: "GenServer terminating",
                     value: "GenServer" <> _
                   }
                 ]
               }
             } = event
    end
  end

  test "genserver crash exit", %{handler_ref: ref, config: %{supervisor_name: supervisor_name}} do
    LoggerHandlerKit.Act.genserver_crash(:exit)
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    if pre_19?() do
      assert %{
               event: "$exception",
               properties: %{
                 "$exception_list": [
                   %{
                     type: "** (exit) \"i quit\"",
                     value: "** (exit) \"i quit\"",
                     mechanism: %{handled: false, type: "generic"},
                     stacktrace: %{
                       type: "raw",
                       frames: [
                         %{
                           in_app: false,
                           filename: "lib/logger_handler_kit/act.ex",
                           function: "anonymous fn/0 in LoggerHandlerKit.Act.genserver_crash/1",
                           lineno: _,
                           module: "LoggerHandlerKit.Act",
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           filename: "gen_server.erl",
                           function: ":gen_server.try_handle_call/4",
                           lineno: _,
                           module: ":gen_server",
                           platform: "custom",
                           lang: "elixir",
                           in_app: false
                         },
                         %{
                           filename: "gen_server.erl",
                           function: ":gen_server.handle_msg" <> _,
                           lineno: _,
                           module: ":gen_server",
                           platform: "custom",
                           lang: "elixir",
                           in_app: false
                         },
                         %{
                           filename: "proc_lib.erl",
                           function: ":proc_lib.init_p_do_apply/3",
                           in_app: false,
                           lineno: _,
                           module: ":proc_lib",
                           platform: "custom",
                           lang: "elixir"
                         }
                       ]
                     }
                   }
                 ]
               }
             } = event
    else
      assert %{
               event: "$exception",
               properties: %{
                 genserver_name: "#PID<" <> _,
                 genserver_state: nil,
                 genserver_last_message: [:run, _fun_name],
                 genserver_process_label: :undefined,
                 genserver_client: "#PID<" <> _,
                 "$exception_list": [
                   %{
                     type: "** (exit) \"i quit\"",
                     value: "** (exit) \"i quit\"",
                     mechanism: %{handled: false, type: "generic"},
                     stacktrace: %{
                       type: "raw",
                       frames: [
                         %{
                           in_app: false,
                           filename: "lib/logger_handler_kit/act.ex",
                           function: "anonymous fn/0 in LoggerHandlerKit.Act.genserver_crash/1",
                           lineno: _,
                           module: "LoggerHandlerKit.Act",
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           filename: "gen_server.erl",
                           function: ":gen_server.try_handle_call/4",
                           lineno: _,
                           module: ":gen_server",
                           platform: "custom",
                           lang: "elixir",
                           in_app: false
                         },
                         %{
                           filename: "gen_server.erl",
                           function: ":gen_server.handle_msg" <> _,
                           lineno: _,
                           module: ":gen_server",
                           platform: "custom",
                           lang: "elixir",
                           in_app: false
                         },
                         %{
                           filename: "proc_lib.erl",
                           function: ":proc_lib.init_p_do_apply/3",
                           in_app: false,
                           lineno: _,
                           module: ":proc_lib",
                           platform: "custom",
                           lang: "elixir"
                         }
                       ]
                     }
                   },
                   %{
                     mechanism: %{handled: true, type: "generic"},
                     type: "GenServer terminating",
                     value: "GenServer" <> _
                   }
                 ]
               }
             } = event
    end
  end

  test "genserver crash exit with struct", %{
    handler_ref: ref,
    config: %{supervisor_name: supervisor_name}
  } do
    LoggerHandlerKit.Act.genserver_crash(:exit_with_struct)
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    if pre_19?() do
      assert %{
               event: "$exception",
               properties: %{
                 "$exception_list": [
                   %{
                     type: "** (exit) %LoggerHandlerKit.FakeStruct{hello: \"world\"}",
                     value: "** (exit) %LoggerHandlerKit.FakeStruct{hello: \"world\"}",
                     mechanism: %{handled: false, type: "generic"}
                   }
                 ]
               }
             } = event
    else
      assert %{
               event: "$exception",
               properties: %{
                 genserver_name: "#PID<" <> _,
                 genserver_state: :no_state,
                 genserver_last_message: [:run, _fun_name],
                 genserver_process_label: :undefined,
                 genserver_client: "#PID<" <> _,
                 "$exception_list": [
                   %{
                     type: "** (exit) %LoggerHandlerKit.FakeStruct{hello: \"world\"}",
                     value: "** (exit) %LoggerHandlerKit.FakeStruct{hello: \"world\"}",
                     mechanism: %{handled: false, type: "generic"}
                   },
                   %{
                     mechanism: %{handled: true, type: "generic"},
                     type: "GenServer terminating",
                     value: "GenServer" <> _
                   }
                 ]
               }
             } = event
    end
  end

  test "genserver crash throw", %{handler_ref: ref, config: %{supervisor_name: supervisor_name}} do
    LoggerHandlerKit.Act.genserver_crash(:throw)
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    if pre_19?() do
      assert %{
               event: "$exception",
               properties: %{
                 "$exception_list": [
                   %{
                     type: "** (exit) bad return value: \"catch!\"",
                     value: "** (exit) bad return value: \"catch!\"",
                     mechanism: %{handled: false, type: "generic"}
                   }
                 ]
               }
             } = event
    else
      assert %{
               event: "$exception",
               properties: %{
                 genserver_name: "#PID<" <> _,
                 genserver_state: nil,
                 genserver_last_message: [:run, _fun_name],
                 genserver_process_label: :undefined,
                 genserver_client: "#PID<" <> _,
                 "$exception_list": [
                   %{
                     type: "** (exit) bad return value: \"catch!\"",
                     value: "** (exit) bad return value: \"catch!\"",
                     mechanism: %{handled: false, type: "generic"}
                   },
                   %{
                     mechanism: %{handled: true, type: "generic"},
                     type: "GenServer terminating",
                     value: "GenServer" <> _
                   }
                 ]
               }
             } = event
    end
  end

  test "gen_state_m crash exception", %{
    handler_ref: ref,
    config: %{supervisor_name: supervisor_name}
  } do
    LoggerHandlerKit.Act.gen_statem_crash(:exception)
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    if pre_19?() do
      assert %{
               event: "$exception",
               properties: %{
                 "$exception_list": [
                   %{
                     type: "RuntimeError",
                     value: "** (RuntimeError) oops",
                     mechanism: %{handled: false, type: "generic"},
                     stacktrace: %{
                       frames: [
                         %{
                           function: "anonymous fn/0 in LoggerHandlerKit.Act.gen_statem_crash/1",
                           module: "LoggerHandlerKit.Act",
                           filename: "lib/logger_handler_kit/act.ex",
                           in_app: false,
                           lineno: _,
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           function: ":gen_statem.loop_state_callback/11",
                           module: ":gen_statem",
                           filename: "gen_statem.erl",
                           in_app: false,
                           lineno: _,
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           function: ":proc_lib.init_p_do_apply/3",
                           module: ":proc_lib",
                           filename: "proc_lib.erl",
                           in_app: false,
                           lineno: _,
                           platform: "custom",
                           lang: "elixir"
                         }
                       ],
                       type: "raw"
                     }
                   }
                 ]
               }
             } = event
    else
      assert %{
               event: "$exception",
               properties: %{
                 gen_statem_name: "#PID<" <> _,
                 gen_statem_state: [:started, nil],
                 gen_statem_queue: [
                   %{
                     call: _,
                     run: _
                   }
                 ],
                 gen_statem_client: "#PID<" <> _,
                 gen_statem_process_label: :undefined,
                 gen_statem_callback_mode: :state_functions,
                 gen_statem_postponed: [],
                 gen_statem_state_enter: false,
                 "$exception_list": [
                   %{
                     type: "RuntimeError",
                     value: "** (RuntimeError) oops",
                     mechanism: %{handled: false, type: "generic"},
                     stacktrace: %{
                       frames: [
                         %{
                           function: "anonymous fn/0 in LoggerHandlerKit.Act.gen_statem_crash/1",
                           module: "LoggerHandlerKit.Act",
                           filename: "lib/logger_handler_kit/act.ex",
                           in_app: false,
                           lineno: _,
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           function: ":gen_statem.loop_state_callback/11",
                           module: ":gen_statem",
                           filename: "gen_statem.erl",
                           in_app: false,
                           lineno: _,
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           function: ":proc_lib.init_p_do_apply/3",
                           module: ":proc_lib",
                           filename: "proc_lib.erl",
                           in_app: false,
                           lineno: _,
                           platform: "custom",
                           lang: "elixir"
                         }
                       ],
                       type: "raw"
                     }
                   },
                   %{
                     mechanism: %{handled: true, type: "generic"},
                     stacktrace: %{
                       frames: [
                         %{
                           function: ":gen.do_call/4",
                           module: ":gen",
                           filename: "gen.erl",
                           in_app: false,
                           lineno: _,
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           function: ":gen_statem.call/3",
                           module: ":gen_statem",
                           filename: "gen_statem.erl",
                           resolved: true,
                           in_app: false,
                           lineno: _,
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           function: "LoggerHandlerKit.Act.gen_statem_crash/1",
                           module: "LoggerHandlerKit.Act",
                           filename: "lib/logger_handler_kit/act.ex",
                           resolved: true,
                           in_app: false,
                           lineno: _,
                           platform: "custom",
                           lang: "elixir"
                         }
                         | _
                       ],
                       type: "raw"
                     },
                     type: ":gen_statem terminating",
                     value: ":gen_statem" <> _
                   }
                 ]
               }
             } = event
    end
  end

  test "bare process crash exception", %{
    handler_id: handler_id,
    handler_ref: ref,
    config: %{supervisor_name: supervisor_name}
  } do
    # We use this call to initialize key ownership. LoggerHandlerKit will share
    # ownership to PostHog.Ownership server, but the key has to be initialized.
    all_captured(supervisor_name)
    LoggerHandlerKit.Act.bare_process_crash(handler_id, :exception)
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    assert %{
             event: "$exception",
             properties: %{
               "$exception_list": [
                 %{
                   type: "RuntimeError",
                   value: "** (RuntimeError) oops",
                   mechanism: %{handled: false, type: "generic"},
                   stacktrace: %{
                     frames: [
                       %{
                         filename: "lib/logger_handler_kit/act.ex",
                         function: "anonymous fn/0 in LoggerHandlerKit.Act.bare_process_crash/2",
                         in_app: false,
                         lineno: _,
                         module: "LoggerHandlerKit.Act",
                         platform: "custom",
                         lang: "elixir"
                       }
                     ],
                     type: "raw"
                   }
                 }
               ]
             }
           } = event
  end

  test "bare process crash throw", %{
    handler_id: handler_id,
    handler_ref: ref,
    config: %{supervisor_name: supervisor_name}
  } do
    # We use this call to initialize key ownership. LoggerHandlerKit will share
    # ownership to PostHog.Ownership server, but the key has to be initialized.
    all_captured(supervisor_name)
    LoggerHandlerKit.Act.bare_process_crash(handler_id, :throw)
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    assert %{
             event: "$exception",
             properties: %{
               "$exception_list": [
                 %{
                   type: "ErlangError",
                   value: "** (ErlangError) Erlang error: {:nocatch, \"catch!\"}",
                   mechanism: %{handled: false, type: "generic"},
                   stacktrace: %{
                     frames: [
                       %{
                         filename: "lib/logger_handler_kit/act.ex",
                         function: "anonymous fn/0 in LoggerHandlerKit.Act.bare_process_crash/2",
                         in_app: false,
                         lineno: _,
                         module: "LoggerHandlerKit.Act",
                         platform: "custom",
                         lang: "elixir"
                       }
                     ],
                     type: "raw"
                   }
                 }
               ]
             }
           } = event
  end

  @tag handle_sasl_reports: true
  test "genserver init crash", %{handler_ref: ref, config: %{supervisor_name: supervisor_name}} do
    LoggerHandlerKit.Act.genserver_init_crash()
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    if pre_19?() do
      assert %{
               event: "$exception",
               properties: %{
                 "$exception_list": [
                   %{
                     type: "RuntimeError",
                     value: "** (RuntimeError) oops",
                     mechanism: %{handled: false, type: "generic"},
                     stacktrace: %{
                       frames: [
                         %{
                           filename: "lib/logger_handler_kit/act.ex",
                           function:
                             "anonymous fn/0 in LoggerHandlerKit.Act.genserver_init_crash/0",
                           in_app: false,
                           lineno: _,
                           module: "LoggerHandlerKit.Act",
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           filename: "gen_server.erl",
                           function: ":gen_server.init_it/2",
                           in_app: false,
                           lineno: _,
                           module: ":gen_server",
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           filename: "gen_server.erl",
                           function: ":gen_server.init_it/6",
                           in_app: false,
                           lineno: _,
                           module: ":gen_server",
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           filename: "proc_lib.erl",
                           function: ":proc_lib.init_p_do_apply/3",
                           in_app: false,
                           lineno: _,
                           module: ":proc_lib",
                           platform: "custom",
                           lang: "elixir"
                         }
                       ],
                       type: "raw"
                     }
                   }
                 ]
               }
             } = event
    else
      assert %{
               event: "$exception",
               properties: %{
                 "$exception_list": [
                   %{
                     type: "RuntimeError",
                     value: "** (RuntimeError) oops",
                     mechanism: %{handled: false, type: "generic"},
                     stacktrace: %{
                       frames: [
                         %{
                           filename: "lib/logger_handler_kit/act.ex",
                           function:
                             "anonymous fn/0 in LoggerHandlerKit.Act.genserver_init_crash/0",
                           in_app: false,
                           lineno: _,
                           module: "LoggerHandlerKit.Act",
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           filename: "gen_server.erl",
                           function: ":gen_server.init_it/2",
                           in_app: false,
                           lineno: _,
                           module: ":gen_server",
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           filename: "gen_server.erl",
                           function: ":gen_server.init_it/6",
                           in_app: false,
                           lineno: _,
                           module: ":gen_server",
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           filename: "proc_lib.erl",
                           function: ":proc_lib.init_p_do_apply/3",
                           in_app: false,
                           lineno: _,
                           module: ":proc_lib",
                           platform: "custom",
                           lang: "elixir"
                         }
                       ],
                       type: "raw"
                     }
                   },
                   %{
                     mechanism: %{handled: true, type: "generic"},
                     type: "Process terminating",
                     value: "Process" <> _
                   }
                 ]
               }
             } = event
    end
  end

  @tag handle_sasl_reports: true
  test "proc_lib crash exception", %{
    handler_ref: ref,
    config: %{supervisor_name: supervisor_name}
  } do
    LoggerHandlerKit.Act.proc_lib_crash(:exception)
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    if pre_19?() do
      assert %{
               event: "$exception",
               properties: %{
                 "$exception_list": [
                   %{
                     type: "RuntimeError",
                     value: "** (RuntimeError) oops",
                     mechanism: %{handled: false, type: "generic"},
                     stacktrace: %{
                       frames: [
                         %{
                           filename: "lib/logger_handler_kit/act.ex",
                           function: "anonymous fn/1 in LoggerHandlerKit.Act.proc_lib_crash/1",
                           in_app: false,
                           lineno: _,
                           module: "LoggerHandlerKit.Act",
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           filename: "proc_lib.erl",
                           function: ":proc_lib.init_p/3",
                           in_app: false,
                           lineno: _,
                           module: ":proc_lib",
                           platform: "custom",
                           lang: "elixir"
                         }
                       ],
                       type: "raw"
                     }
                   }
                 ]
               }
             } = event
    else
      assert %{
               event: "$exception",
               properties: %{
                 "$exception_list": [
                   %{
                     type: "RuntimeError",
                     value: "** (RuntimeError) oops",
                     mechanism: %{handled: false, type: "generic"},
                     stacktrace: %{
                       frames: [
                         %{
                           filename: "lib/logger_handler_kit/act.ex",
                           function: "anonymous fn/1 in LoggerHandlerKit.Act.proc_lib_crash/1",
                           in_app: false,
                           lineno: _,
                           module: "LoggerHandlerKit.Act",
                           platform: "custom",
                           lang: "elixir"
                         },
                         %{
                           filename: "proc_lib.erl",
                           function: ":proc_lib.init_p/3",
                           in_app: false,
                           lineno: _,
                           module: ":proc_lib",
                           platform: "custom",
                           lang: "elixir"
                         }
                       ],
                       type: "raw"
                     }
                   },
                   %{
                     mechanism: %{handled: true, type: "generic"},
                     type: "Process terminating",
                     value: "Process" <> _
                   }
                 ]
               }
             } = event
    end
  end

  @tag handle_sasl_reports: true
  test "supervisor progress report failed to start child", %{
    handler_ref: ref,
    config: %{supervisor_name: supervisor_name}
  } do
    LoggerHandlerKit.Act.supervisor_progress_report(:failed_to_start_child)
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    assert %{
             event: "$exception",
             properties: %{
               "$exception_list": [
                 %{
                   type: "Child :task of Supervisor" <> type_end,
                   value: "Child :task of Supervisor" <> value_end,
                   mechanism: %{handled: true, type: "generic"}
                 }
               ]
             }
           } = event

    assert String.ends_with?(type_end, "failed to start")
    assert String.ends_with?(value_end, "\nType: :worker")
  end

  @tag handle_sasl_reports: true, config: [capture_level: :debug]
  test "supervisor progress report child started", %{
    handler_ref: ref,
    config: %{supervisor_name: supervisor_name}
  } do
    LoggerHandlerKit.Act.supervisor_progress_report(:child_started)
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    assert %{
             event: "$exception",
             properties: %{
               "$exception_list": [
                 %{
                   type: "Child :task of Supervisor" <> type_end,
                   value: "Child :task of Supervisor" <> value_end,
                   mechanism: %{handled: true, type: "generic"}
                 }
               ]
             }
           } = event

    assert String.ends_with?(type_end, "started")
    assert String.ends_with?(value_end, "\nType: :worker")
  end

  @tag handle_sasl_reports: true
  test "supervisor progress report child terminated", %{
    handler_ref: ref,
    config: %{supervisor_name: supervisor_name}
  } do
    # We use this call to initialize key ownership. LoggerHandlerKit will share
    # ownership to PostHog.Ownership server, but the key has to be initialized.
    all_captured(supervisor_name)
    LoggerHandlerKit.Act.supervisor_progress_report(:child_terminated)
    LoggerHandlerKit.Assert.assert_logged(ref)
    LoggerHandlerKit.Assert.assert_logged(ref)
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [_, _, _] = events = all_captured(supervisor_name)

    for event <- events do
      assert %{
               event: "$exception",
               properties: %{
                 "$exception_list": [
                   %{
                     type: "Child :task of Supervisor" <> type_end,
                     mechanism: %{handled: true, type: "generic"}
                   }
                 ]
               }
             } = event

      assert Enum.any?([
               String.ends_with?(type_end, "started"),
               String.ends_with?(type_end, "terminated"),
               String.ends_with?(type_end, "caused shutdown")
             ])
    end
  end

  @tag config: [metadata: [:extra]]
  test "exports metadata if configured", %{
    handler_ref: ref,
    config: %{supervisor_name: supervisor_name}
  } do
    Logger.error("Error with metadata", extra: "Foo", hello: "world")
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    assert %{
             event: "$exception",
             properties: %{
               extra: "Foo",
               "$exception_list": [
                 %{
                   type: "Error with metadata",
                   value: "Error with metadata",
                   mechanism: %{handled: true}
                 }
               ]
             }
           } = event
  end

  @tag config: [metadata: :all]
  test "exports all metadata if configured", %{
    handler_ref: ref,
    config: %{supervisor_name: supervisor_name}
  } do
    PostHog.set_context(supervisor_name, %{should: "work"})
    PostHog.set_context(%{shouldnt: "work"})
    Logger.metadata(foo: "bar")
    Logger.error("Error with metadata", hello: "world")
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    assert %{
             event: "$exception",
             properties:
               %{
                 hello: "world",
                 foo: "bar",
                 should: "work",
                 "$exception_list": [
                   %{
                     type: "Error with metadata",
                     value: "Error with metadata",
                     mechanism: %{handled: true}
                   }
                 ]
               } = properties
           } = event

    refute Map.has_key?(properties, :shouldnt)
  end

  @tag config: [metadata: :all]
  test "updates file metadata to be a string", %{
    handler_ref: ref,
    config: %{supervisor_name: supervisor_name}
  } do
    Logger.error("Error with default metadata")
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [%{properties: %{file: file}}] = all_captured(supervisor_name)
    assert is_binary(file)
  end

  @tag config: [metadata: :all]
  test "noop if file is non chardata", %{
    handler_ref: ref,
    config: %{supervisor_name: supervisor_name}
  } do
    Logger.error("Error with default metadata", file: 123)
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [%{properties: %{file: 123}}] = all_captured(supervisor_name)
  end

  @tag config: [metadata: [:extra]]
  test "ensures metadata is serializable", %{
    handler_ref: ref,
    config: %{supervisor_name: supervisor_name}
  } do
    LoggerHandlerKit.Act.metadata_serialization(:all)
    LoggerHandlerKit.Act.string_message()
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    assert %{
             event: "$exception",
             properties: %{extra: maybe_encoded}
           } = event

    assert %{
             boolean: true,
             string: "hello world",
             binary: "<<1, 2, 3>>",
             atom: :foo,
             integer: 42,
             datetime: ~U[2025-06-01 12:34:56.000Z],
             struct: %{hello: "world"},
             tuple: [:ok, "hello"],
             keyword: %{hello: "world"},
             improper_keyword: "[[:a, 1] | {:b, 2}]",
             fake_keyword: [[:a, 1], [:b, 2, :c]],
             list: [1, 2, 3],
             improper_list: "[1, 2 | 3]",
             map: %{:hello => "world", "foo" => "bar"},
             function: "&LoggerHandlerKit.Act.metadata_serialization/1",
             anonymous_function: "#Function<" <> _,
             pid: "#PID<" <> _,
             ref: "#Reference<" <> _,
             port: "#Port<" <> _
           } = maybe_encoded

    Jason.encode!(maybe_encoded)
  end

  @tag config: [metadata: [:extra]]
  test "purposefully set context is always exported", %{config: config, handler_ref: ref} do
    PostHog.set_context(config.supervisor_name, %{foo: "bar"})
    Logger.error("Error with metadata", hello: "world")
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(config.supervisor_name)

    assert %{
             event: "$exception",
             properties: %{
               foo: "bar",
               "$exception_list": [
                 %{
                   type: "Error with metadata",
                   value: "Error with metadata",
                   mechanism: %{handled: true, type: "generic"}
                 }
               ]
             }
           } = event
  end

  test "erlang frames in stacktrace", %{
    handler_ref: ref,
    config: %{supervisor_name: supervisor_name}
  } do
    {:ok, _pid} = Task.start(fn -> :erlang.system_time(:foo) end)
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    if pre_19?() do
      assert %{
               event: "$exception",
               properties: %{
                 "$exception_list": [
                   %{
                     type: "ArgumentError",
                     value:
                       "** (ArgumentError) errors were found at the given arguments:\n\n  * 1st argument: invalid time unit\n",
                     stacktrace: %{
                       type: "raw",
                       frames: [
                         %{
                           filename: "",
                           function: ":erlang.system_time(:foo)",
                           in_app: false,
                           lineno: nil,
                           module: ":erlang",
                           platform: "custom",
                           lang: "elixir"
                         }
                         | _
                       ]
                     },
                     mechanism: %{type: "generic", handled: false}
                   }
                 ]
               }
             } = event
    else
      assert %{
               event: "$exception",
               properties: %{
                 "$exception_list": [
                   %{
                     type: "ArgumentError",
                     value:
                       "** (ArgumentError) errors were found at the given arguments:\n\n  * 1st argument: invalid time unit\n",
                     stacktrace: %{
                       type: "raw",
                       frames: [
                         %{
                           filename: "",
                           function: ":erlang.system_time(:foo)",
                           in_app: false,
                           lineno: nil,
                           module: ":erlang",
                           platform: "custom",
                           lang: "elixir"
                         }
                         | _
                       ]
                     },
                     mechanism: %{type: "generic", handled: false}
                   },
                   %{
                     mechanism: %{handled: true, type: "generic"},
                     type: "Task terminating"
                   }
                 ]
               }
             } = event
    end
  end

  @tag config: [in_app_otp_apps: [:logger_handler_kit]]
  test "marks in_app frames as such", %{
    handler_ref: ref,
    config: %{supervisor_name: supervisor_name}
  } do
    LoggerHandlerKit.Act.task_error(:exception)
    LoggerHandlerKit.Assert.assert_logged(ref)

    assert [event] = all_captured(supervisor_name)

    if pre_19?() do
      assert %{
               event: "$exception",
               properties: %{
                 "$exception_list": [
                   %{
                     stacktrace: %{
                       type: "raw",
                       frames: [
                         %{
                           in_app: true,
                           module: "LoggerHandlerKit.Act"
                         },
                         %{
                           in_app: false,
                           module: "Task.Supervised"
                         }
                       ]
                     }
                   }
                 ]
               }
             } = event
    else
      assert %{
               event: "$exception",
               properties: %{
                 "$exception_list": [
                   %{
                     stacktrace: %{
                       type: "raw",
                       frames: [
                         %{
                           in_app: true,
                           module: "LoggerHandlerKit.Act"
                         },
                         %{
                           in_app: false,
                           module: "Task.Supervised"
                         }
                       ]
                     }
                   },
                   _
                 ]
               }
             } = event
    end
  end
end
