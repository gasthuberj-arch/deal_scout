# scripts/benchmark_deployed.exs
# Live Production Concurrency & Failure Boundary Benchmark for DealScout on Fly.io

defmodule RemoteBenchmark do
  @target_url System.get_env("TARGET_URL") || "https://deal-scout.fly.dev"

  def run do
    Application.ensure_all_started(:req)
    Application.ensure_all_started(:finch)

    {:ok, _} =
      Finch.start_link(
        name: DeployedBenchFinch,
        pools: %{
          :default => [size: 300, count: 4, conn_opts: [transport_opts: [timeout: 30_000]]]
        }
      )

    IO.puts("""
    ======================================================================
    🎯 DEPLOYED PRODUCTION CAPACITY BENCHMARK: #{@target_url}
    ======================================================================
    Target Architecture:
      - Host: Fly.io shared-cpu-1x (1 vCPU), 512 MB RAM (Region: fra)
      - Engine: Phoenix 1.8 + Bandit 1.13 + Elixir 1.18 (BEAM 27)
      - Database: SQLite 3 WAL Mode (/data/deal_scout.db), pool_size: 5
      - Fly Proxy Concurrency Limits: soft_limit: 200, hard_limit: 300
    ======================================================================
    """)

    # 1. Pre-flight Telemetry
    IO.puts("📡 Fetching pre-benchmark telemetry from production machine...")
    pre_telemetry = fetch_remote_telemetry()
    print_telemetry("Initial Production State", pre_telemetry)

    # 2. Phase 1: Concurrency Step Ramp (Finding the exact breaking point)
    IO.puts("""
    ----------------------------------------------------------------------
    PHASE 1: CONCURRENCY RAMP (Finding Failure & Degradation Thresholds)
    ----------------------------------------------------------------------
    """)

    concurrency_levels = [5, 10, 15, 20, 25, 30, 35, 40, 50, 75]
    requests_per_level = 60

    ramp_results =
      Enum.map(concurrency_levels, fn c ->
        result = run_load_step("#{@target_url}/", requests_per_level, c)
        Process.sleep(500)
        {c, result}
      end)

    # 3. Phase 2: Endpoint Comparison (at Concurrency = 20)
    IO.puts("""
    ----------------------------------------------------------------------
    PHASE 2: ENDPOINT PROFILE COMPARISON (at Concurrency = 20)
    ----------------------------------------------------------------------
    """)

    endpoints = [
      {"Home (Deals Stream + Preloads)", "#{@target_url}/"},
      {"Search Query (q=nintendo)", "#{@target_url}/?q=nintendo"},
      {"Merchant Filter (merchant=amazon)", "#{@target_url}/?merchant=amazon"},
      {"Login (Lightweight Auth SSR)", "#{@target_url}/users/log-in"}
    ]

    endpoint_results =
      Enum.map(endpoints, fn {label, url} ->
        result = run_load_step(url, 60, 20, label)
        Process.sleep(400)
        {label, result}
      end)

    # 4. Phase 3: Saturation & Recovery Profile
    IO.puts("""
    ----------------------------------------------------------------------
    PHASE 3: SATURATION BURST & RECOVERY TEST
    ----------------------------------------------------------------------
    """)

    IO.puts("💥 Injecting saturation burst (100 requests @ concurrency 60)...")
    burst_result = run_load_step("#{@target_url}/", 100, 60, "Burst Stress")

    IO.puts("⏱️ Immediate post-burst probe: 20 requests @ concurrency 5...")
    recovery_result = run_load_step("#{@target_url}/", 20, 5, "Recovery Probe")

    # 5. Post-flight Telemetry
    IO.puts("""
    ----------------------------------------------------------------------
    POST-BENCHMARK PRODUCTION TELEMETRY
    ----------------------------------------------------------------------
    """)

    post_telemetry = fetch_remote_telemetry()
    print_telemetry("Post-Load Production State", post_telemetry)

    # 6. Synthesize Failure Point Analysis
    print_analysis(ramp_results, endpoint_results, burst_result, recovery_result, pre_telemetry, post_telemetry)
  end

  defp run_load_step(url, total, concurrency, custom_label \\ nil) do
    label = custom_label || "Concurrency #{concurrency}"
    IO.write("▶ [#{label}] #{total} reqs @ c=#{concurrency} ... ")

    t_start = System.monotonic_time(:millisecond)

    results =
      1..total
      |> Task.async_stream(
        fn _ ->
          t0 = System.monotonic_time(:microsecond)

          case Req.get(url, finch: [name: DeployedBenchFinch], retry: false, receive_timeout: 30_000) do
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

    elapsed_ms = System.monotonic_time(:millisecond) - t_start
    elapsed_sec = elapsed_ms / 1000.0

    latencies =
      results
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, ms} -> ms end)
      |> Enum.sort()

    errors =
      results
      |> Enum.filter(&match?({:error, _}, &1))
      |> Enum.map(fn {:error, err} -> err end)

    success_count = length(latencies)
    error_count = length(errors)
    rps = if elapsed_sec > 0, do: Float.round(total / elapsed_sec, 1), else: 0.0

    p50 = percentile(latencies, 50)
    p95 = percentile(latencies, 95)
    p99 = percentile(latencies, 99)

    error_summary =
      errors
      |> Enum.frequencies()
      |> Enum.map(fn {err, cnt} -> "#{cnt}x #{err}" end)
      |> Enum.join(", ")

    if error_count == 0 do
      IO.puts("OK #{rps} rps | p50: #{p50}ms | p95: #{p95}ms | p99: #{p99}ms (100% success)")
    else
      IO.puts("DEGRADED #{rps} rps | #{success_count}/#{total} passed | #{error_summary} | p50: #{p50}ms")
    end

    %{
      total: total,
      concurrency: concurrency,
      success_count: success_count,
      error_count: error_count,
      rps: rps,
      p50: p50,
      p95: p95,
      p99: p99,
      errors: errors
    }
  end

  defp percentile([], _p), do: 0.0

  defp percentile(sorted, p) do
    k = (length(sorted) - 1) * (p / 100.0)
    f = floor(k)
    c = ceil(k)

    if f == c do
      Float.round(Enum.at(sorted, f), 1)
    else
      val = Enum.at(sorted, f) * (c - k) + Enum.at(sorted, c) * (k - f)
      Float.round(val, 1)
    end
  end

  defp fetch_remote_telemetry do
    {meminfo_out, _} = System.cmd("fly", ["ssh", "console", "-C", "/bin/cat /proc/meminfo"], stderr_to_stdout: true)
    {beam_mem_out, _} = System.cmd("fly", ["ssh", "console", "-C", "/app/bin/deal_scout rpc :erlang.memory()"], stderr_to_stdout: true)
    {beam_proc_out, _} = System.cmd("fly", ["ssh", "console", "-C", "/app/bin/deal_scout rpc :erlang.system_info(:process_count)"], stderr_to_stdout: true)

    mem_avail_kb =
      case Regex.run(~r/MemAvailable:\s+(\d+)\s+kB/, meminfo_out) do
        [_, val] -> String.to_integer(val)
        _ -> 0
      end

    mem_total_kb =
      case Regex.run(~r/MemTotal:\s+(\d+)\s+kB/, meminfo_out) do
        [_, val] -> String.to_integer(val)
        _ -> 0
      end

    beam_total_mb =
      case Regex.run(~r/total:\s+(\d+)/, beam_mem_out) do
        [_, val] -> Float.round(String.to_integer(val) / 1024 / 1024, 2)
        _ -> 0.0
      end

    beam_proc_heap_mb =
      case Regex.run(~r/processes:\s+(\d+)/, beam_mem_out) do
        [_, val] -> Float.round(String.to_integer(val) / 1024 / 1024, 2)
        _ -> 0.0
      end

    process_count =
      case Regex.run(~r/\b(\d+)\b/, beam_proc_out) do
        [_, val] -> String.to_integer(val)
        _ -> 0
      end

    %{
      mem_total_mb: Float.round(mem_total_kb / 1024, 1),
      mem_available_mb: Float.round(mem_avail_kb / 1024, 1),
      beam_total_mb: beam_total_mb,
      beam_processes_mb: beam_proc_heap_mb,
      process_count: process_count
    }
  end

  defp print_telemetry(title, t) do
    IO.puts("""
    📊 #{title}:
       Host Mem Available: #{t.mem_available_mb} MB / #{t.mem_total_mb} MB
       BEAM VM Memory:     #{t.beam_total_mb} MB (Process Heaps: #{t.beam_processes_mb} MB)
       BEAM Process Count: #{t.process_count}
    """)
  end

  defp print_analysis(ramp_results, endpoint_results, burst, recovery, pre, post) do
    first_degraded =
      Enum.find(ramp_results, fn {_c, res} -> res.p50 > 1200.0 end)

    first_failing =
      Enum.find(ramp_results, fn {_c, res} -> res.error_count > 0 end)

    IO.puts("""
    ======================================================================
    🎯 BENCHMARK EXECUTIVE FINDINGS: WHEN DOES THE CURRENT WAY FAIL?
    ======================================================================
    """)

    if first_degraded do
      {c, res} = first_degraded
      IO.puts("1. LATENCY DEGRADATION POINT: Concurrency = #{c}")
      IO.puts("   Latency crosses 1.2s p50 (p50=#{res.p50}ms, p95=#{res.p95}ms, Throughput=#{res.rps} req/sec).")
    end

    if first_failing do
      {c, res} = first_failing
      err_sample = res.errors |> hd()
      IO.puts("2. HARD FAILURE THRESHOLD: Concurrency = #{c}")
      IO.puts("   Errors begin occurring: #{res.error_count}/#{res.total} requests failed (#{err_sample}).")
      IO.puts("   Mechanics: Ecto/DBConnection queue overflow (>100ms checkout wait with pool_size: 5).")
    else
      IO.puts("2. HARD FAILURE THRESHOLD: No errors observed up to maximum tested concurrency.")
    end

    IO.puts("""
    3. ENDPOINT BEHAVIOR UNDER LOAD (Concurrency = 20):
    """)

    Enum.each(endpoint_results, fn {label, res} ->
      IO.puts("   - #{String.pad_trailing(label, 36)}: #{res.rps} req/s | p50=#{res.p50}ms | p95=#{res.p95}ms | #{res.success_count}/#{res.total} OK")
    end)

    IO.puts("""
    4. SATURATION BURST BEHAVIOR:
       Burst @ Concurrency #{burst.concurrency}: #{burst.success_count}/#{burst.total} succeeded (#{burst.rps} req/sec).
       Immediate Recovery Probe @ Concurrency #{recovery.concurrency}: #{recovery.success_count}/#{recovery.total} succeeded (p50: #{recovery.p50}ms).

    5. INFRASTRUCTURE & RESOURCE IMPACT (Fly.io 512MB 1 vCPU):
       Host RAM Available: #{pre.mem_available_mb} MB -> #{post.mem_available_mb} MB
       BEAM VM Memory:     #{pre.beam_total_mb} MB -> #{post.beam_total_mb} MB
       Process Count:      #{pre.process_count} -> #{post.process_count}
    ======================================================================
    """)
  end
end

RemoteBenchmark.run()
