# Exclude the unmocked tests by default
ExUnit.configure(exclude: :integration, assert_receive_timeout: 1000)

ExUnit.start()
