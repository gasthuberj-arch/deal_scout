# scripts/loadtest.exs
# Comprehensive load testing and concurrency benchmark for DealScout

defmodule LoadTest do
  @base_url System.get_env("TARGET_URL") || "http://localhost:#{System.get_env("PORT", "4000")}"

  def run do
    {:ok, _} = Finch.start_link(
      name: LoadTestFinch,
      pools: %{
        :default => [size: 250, count: 4, conn_opts: [transport_opts: [timeout: 30_000]]]
      }
    )

    IO.puts("""
    ======================================================================
    🎯 DEALSCOUT REAL-TIME LOAD TEST & CONCURRENCY BENCHMARK
    Target: #{@base_url}
    Erlang/OTP: #{:erlang.system_info(:otp_release)} | Schedulers: #{System.schedulers_online()}
    ======================================================================
    """)

    initial_memory = get_memory_stats()
    IO.puts("📊 Initial BEAM VM Memory: #{initial_memory.total_mb} MB (Processes: #{initial_memory.process_mb} MB, System: #{initial_memory.system_mb} MB)")
    IO.puts("👥 Initial BEAM Process Count: #{:erlang.system_info(:process_count)}")
    IO.puts("")

    # Stage 0: Warmup
    IO.puts("🔥 Warming up HTTP pipeline...")
    run_stage("Warmup", total_requests: 20, concurrency: 5)

    # Stage 1: 25 concurrent users
    run_stage("Stage 1: 25 Concurrent Users", total_requests: 100, concurrency: 25)

    # Stage 2: 50 concurrent users
    run_stage("Stage 2: 50 Concurrent Users", total_requests: 200, concurrency: 50)

    # Stage 3: 100 concurrent users
    run_stage("Stage 3: 100 Concurrent Users", total_requests: 300, concurrency: 100)

    # Stage 4: 200 concurrent users
    run_stage("Stage 4: 200 Concurrent Users", total_requests: 400, concurrency: 200)

    IO.puts("""
    ----------------------------------------------------------------------
    ⚡ PUBSUB FAN-OUT BENCHMARK (Simulating Real-Time Deal Push Alerts)
    ----------------------------------------------------------------------
    """)
    benchmark_pubsub_fanout([500, 2_000, 5_000, 10_000])

    post_memory = get_memory_stats()
    IO.puts("""
    ======================================================================
    🏁 FINAL BENCHMARK SUMMARY & CAPACITY ANALYSIS
    ======================================================================
    BEAM VM Memory: #{post_memory.total_mb} MB (Growth: #{Float.round(post_memory.total_mb - initial_memory.total_mb, 2)} MB)
    Active Process Count: #{:erlang.system_info(:process_count)}
    Schedulers Online: #{System.schedulers_online()}
    """)
  end

  def run_stage(title, total_requests: total, concurrency: concurrency) do
    IO.puts("▶ Running #{title} (Requests: #{total}, Concurrency: #{concurrency})...")

    start_time = System.monotonic_time(:millisecond)

    results =
      1..total
      |> Task.async_stream(
        fn _i ->
          t0 = System.monotonic_time(:microsecond)

          case Req.get("#{@base_url}/", finch: [name: LoadTestFinch], retry: false, receive_timeout: 30_000) do
            {:ok, %{status: 200}} ->
              t1 = System.monotonic_time(:microsecond)
              {:ok, (t1 - t0) / 1000.0}

            {:ok, %{status: status}} ->
              {:error, "HTTP #{status}"}

            {:error, reason} ->
              {:error, inspect(reason)}
          end
        end,
        max_concurrency: concurrency,
        timeout: :infinity
      )
      |> Enum.map(fn
        {:ok, res} -> res
        {:exit, reason} -> {:error, "Exit: #{inspect(reason)}"}
      end)

    elapsed_ms = System.monotonic_time(:millisecond) - start_time
    elapsed_sec = elapsed_ms / 1000.0

    latencies =
      results
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, ms} -> ms end)
      |> Enum.sort()

    errors = Enum.filter(results, &match?({:error, _}, &1))
    success_count = length(latencies)
    error_count = length(errors)
    rps = if elapsed_sec > 0, do: Float.round(total / elapsed_sec, 1), else: 0.0

    p50 = percentile(latencies, 50)
    p90 = percentile(latencies, 90)
    p95 = percentile(latencies, 95)
    p99 = percentile(latencies, 99)
    min = if latencies != [], do: Float.round(hd(latencies), 2), else: 0.0
    max = if latencies != [], do: Float.round(List.last(latencies), 2), else: 0.0

    IO.puts("  ✓ Completed in: #{Float.round(elapsed_sec, 2)}s | Throughput: #{rps} req/sec")
    IO.puts("  ✓ Success Rate: #{success_count}/#{total} (#{Float.round(success_count / total * 100, 1)}%)")
    if error_count > 0 do
      sample_err = errors |> hd() |> elem(1)
      IO.puts("  ⚠️ Errors: #{error_count} (Sample: #{sample_err})")
    end
    IO.puts("  ✓ Latencies: min=#{min}ms | p50=#{p50}ms | p90=#{p90}ms | p95=#{p95}ms | p99=#{p99}ms | max=#{max}ms")
    IO.puts("")
  end

  def benchmark_pubsub_fanout(subscriber_counts) do
    for count <- subscriber_counts do
      topic = "benchmark:fanout:#{count}"

      # Spawn N mock LiveView subscriber processes
      subscribers =
        for _i <- 1..count do
          spawn_link(fn ->
            Phoenix.PubSub.subscribe(DealScout.PubSub, topic)
            receive do
              {:deal_alert, _payload} -> :ok
            after
              5000 -> :timeout
            end
          end)
        end

      # Allow subscriptions to register
      Process.sleep(50)

      # Measure broadcast time
      t0 = System.monotonic_time(:microsecond)
      Phoenix.PubSub.broadcast(DealScout.PubSub, topic, {:deal_alert, %{id: 1, title: "RTX 4080", price: 799.00}})
      broadcast_duration_us = System.monotonic_time(:microsecond) - t0
      broadcast_duration_ms = Float.round(broadcast_duration_us / 1000.0, 3)

      IO.puts("  🚀 #{count} Connected LiveView Subscribers: Broadcast fan-out completed in #{broadcast_duration_ms} ms")

      # Cleanup
      Enum.each(subscribers, fn pid ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end)
    end
    IO.puts("")
  end

  defp percentile([], _p), do: 0.0
  defp percentile(sorted_list, p) do
    k = (length(sorted_list) - 1) * (p / 100.0)
    f = floor(k)
    c = ceil(k)
    if f == c do
      Float.round(Enum.at(sorted_list, f), 2)
    else
      val = Enum.at(sorted_list, f) * (c - k) + Enum.at(sorted_list, c) * (k - f)
      Float.round(val, 2)
    end
  end

  defp get_memory_stats do
    mem = :erlang.memory()
    %{
      total_mb: Float.round(mem[:total] / 1024 / 1024, 2),
      process_mb: Float.round(mem[:processes] / 1024 / 1024, 2),
      system_mb: Float.round(mem[:system] / 1024 / 1024, 2)
    }
  end
end

LoadTest.run()
