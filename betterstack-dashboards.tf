# Better Stack dashboards for the willpxxr-live cluster's observability stack.
# Three dashboards: OTEL Agent (DaemonSet), OTEL Gateway (Deployment), Cilium/Hubble.
# All dashboards source from logtail_source.otel_collector (willpxxr-live-otel-collector).

resource "logtail_dashboard_group" "observability" {
  name = "Observability"
}

# ── OTEL Collector — Agent ────────────────────────────────────────────────────
# DaemonSet: filelog (container log tailing), host metrics, kubelet stats.
# SLIs: log ingestion throughput, export success, export queue, file consumer.

resource "logtail_dashboard" "otel_agent" {
  name               = "OTEL Collector — Agent"
  dashboard_group_id = logtail_dashboard_group.observability.id
  date_range_from    = "now-3h"
  date_range_to      = "now"

  variable {
    name          = "source"
    variable_type = "source"
    values        = [logtail_source.otel_collector.id]
  }
}

resource "logtail_dashboard_section" "otel_agent_log_pipeline" {
  dashboard_id = logtail_dashboard.otel_agent.id
  name         = "Log Pipeline"
  y            = 0
}

resource "logtail_dashboard_chart" "otel_agent_log_receive_rate" {
  dashboard_id = logtail_dashboard.otel_agent.id
  name         = "Log Records Received/s"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 0
  y            = 1
  settings     = jsonencode({ unit = "rps", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(rate_avg) AS value
      FROM
        {{source}}
      WHERE
        dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'otelcol_receiver_accepted_log_records'
      GROUP BY
        time
      ORDER BY
        time
    SQL
  }
}

resource "logtail_dashboard_chart" "otel_agent_log_fail_rate" {
  dashboard_id = logtail_dashboard.otel_agent.id
  name         = "Log Records Failed/s"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 6
  y            = 1
  settings     = jsonencode({ unit = "rps", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(rate_avg) AS value
      FROM
        {{source}}
      WHERE
        dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'otelcol_receiver_failed_log_records'
      GROUP BY
        time
      ORDER BY
        time
    SQL
  }
}

resource "logtail_dashboard_chart" "otel_agent_log_export_rate" {
  dashboard_id = logtail_dashboard.otel_agent.id
  name         = "Log Records Exported/s"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 0
  y            = 9
  settings     = jsonencode({ unit = "rps", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(rate_avg) AS value
      FROM
        {{source}}
      WHERE
        dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'otelcol_exporter_sent_log_records'
      GROUP BY
        time
      ORDER BY
        time
    SQL
  }
}

resource "logtail_dashboard_chart" "otel_agent_export_queue" {
  dashboard_id = logtail_dashboard.otel_agent.id
  name         = "Export Queue Utilisation"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 6
  y            = 9
  settings     = jsonencode({ unit = "percent", y_axis_min = 0, y_axis_max = 100, treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMergeIf(value_avg, name = 'otelcol_exporter_queue_size') /
        nullIf(avgMergeIf(value_avg, name = 'otelcol_exporter_queue_capacity'), 0) * 100 AS value
      FROM
        {{source}}
      WHERE
        dt BETWEEN {{start_time}} AND {{end_time}}
        AND name IN ('otelcol_exporter_queue_size', 'otelcol_exporter_queue_capacity')
      GROUP BY
        time
      ORDER BY
        time
    SQL
  }
}

resource "logtail_dashboard_section" "otel_agent_file_consumer" {
  dashboard_id = logtail_dashboard.otel_agent.id
  name         = "File Consumer"
  y            = 17
}

resource "logtail_dashboard_chart" "otel_agent_open_files" {
  dashboard_id = logtail_dashboard.otel_agent.id
  name         = "Open Log Files"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 0
  y            = 18
  settings     = jsonencode({ unit = "shortened", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(value_avg) AS value
      FROM
        {{source}}
      WHERE
        dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'otelcol_fileconsumer_open_files'
      GROUP BY
        time
      ORDER BY
        time
    SQL
  }
}

resource "logtail_dashboard_chart" "otel_agent_reading_files" {
  dashboard_id = logtail_dashboard.otel_agent.id
  name         = "Actively Reading Files"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 6
  y            = 18
  settings     = jsonencode({ unit = "shortened", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(value_avg) AS value
      FROM
        {{source}}
      WHERE
        dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'otelcol_fileconsumer_reading_files'
      GROUP BY
        time
      ORDER BY
        time
    SQL
  }
}

resource "logtail_dashboard_section" "otel_agent_process" {
  dashboard_id = logtail_dashboard.otel_agent.id
  name         = "Process"
  y            = 26
}

resource "logtail_dashboard_chart" "otel_agent_memory_rss" {
  dashboard_id = logtail_dashboard.otel_agent.id
  name         = "Memory RSS"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 0
  y            = 27
  settings     = jsonencode({ unit = "B_iec" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(value_avg) AS value
      FROM
        {{source}}
      WHERE
        dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'otelcol_process_memory_rss'
      GROUP BY
        time
      ORDER BY
        time
    SQL
  }
}

resource "logtail_dashboard_chart" "otel_agent_processor_efficiency" {
  dashboard_id = logtail_dashboard.otel_agent.id
  name         = "Processor Drop Rate (incoming vs outgoing)"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 6
  y            = 27
  settings     = jsonencode({ unit = "rps", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMergeIf(rate_avg, name = 'otelcol_processor_incoming_items') AS incoming,
        avgMergeIf(rate_avg, name = 'otelcol_processor_outgoing_items') AS outgoing
      FROM
        {{source}}
      WHERE
        dt BETWEEN {{start_time}} AND {{end_time}}
        AND name IN ('otelcol_processor_incoming_items', 'otelcol_processor_outgoing_items')
      GROUP BY
        time
      ORDER BY
        time
    SQL
  }
}

# ── OTEL Collector — Gateway ──────────────────────────────────────────────────
# Deployment: k8s_cluster receiver, k8sobjects (events), Prometheus pod scraping,
# OTLP receiver for Envoy traces.
# SLIs: metric ingestion/export throughput, scrape health, queue, pod table size.

resource "logtail_dashboard" "otel_gateway" {
  name               = "OTEL Collector — Gateway"
  dashboard_group_id = logtail_dashboard_group.observability.id
  date_range_from    = "now-3h"
  date_range_to      = "now"

  variable {
    name          = "source"
    variable_type = "source"
    values        = [logtail_source.otel_collector.id]
  }
}

resource "logtail_dashboard_section" "otel_gateway_metrics_pipeline" {
  dashboard_id = logtail_dashboard.otel_gateway.id
  name         = "Metrics Pipeline"
  y            = 0
}

resource "logtail_dashboard_chart" "otel_gateway_metric_receive_rate" {
  dashboard_id = logtail_dashboard.otel_gateway.id
  name         = "Metric Points Received/s"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 0
  y            = 1
  settings     = jsonencode({ unit = "rps", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(rate_avg) AS value
      FROM
        {{source}}
      WHERE
        dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'otelcol_receiver_accepted_metric_points'
      GROUP BY
        time
      ORDER BY
        time
    SQL
  }
}

resource "logtail_dashboard_chart" "otel_gateway_metric_fail_rate" {
  dashboard_id = logtail_dashboard.otel_gateway.id
  name         = "Metric Points Failed/s"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 6
  y            = 1
  settings     = jsonencode({ unit = "rps", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(rate_avg) AS value
      FROM
        {{source}}
      WHERE
        dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'otelcol_receiver_failed_metric_points'
      GROUP BY
        time
      ORDER BY
        time
    SQL
  }
}

resource "logtail_dashboard_chart" "otel_gateway_metric_export_rate" {
  dashboard_id = logtail_dashboard.otel_gateway.id
  name         = "Metric Points Exported/s"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 0
  y            = 9
  settings     = jsonencode({ unit = "rps", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(rate_avg) AS value
      FROM
        {{source}}
      WHERE
        dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'otelcol_exporter_sent_metric_points'
      GROUP BY
        time
      ORDER BY
        time
    SQL
  }
}

resource "logtail_dashboard_chart" "otel_gateway_export_queue" {
  dashboard_id = logtail_dashboard.otel_gateway.id
  name         = "Export Queue Utilisation"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 6
  y            = 9
  settings     = jsonencode({ unit = "percent", y_axis_min = 0, y_axis_max = 100, treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMergeIf(value_avg, name = 'otelcol_exporter_queue_size') /
        nullIf(avgMergeIf(value_avg, name = 'otelcol_exporter_queue_capacity'), 0) * 100 AS value
      FROM
        {{source}}
      WHERE
        dt BETWEEN {{start_time}} AND {{end_time}}
        AND name IN ('otelcol_exporter_queue_size', 'otelcol_exporter_queue_capacity')
      GROUP BY
        time
      ORDER BY
        time
    SQL
  }
}

resource "logtail_dashboard_section" "otel_gateway_scrape_health" {
  dashboard_id = logtail_dashboard.otel_gateway.id
  name         = "Scrape Health"
  y            = 17
}

resource "logtail_dashboard_chart" "otel_gateway_targets_up" {
  dashboard_id = logtail_dashboard.otel_gateway.id
  name         = "Targets Up"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 0
  y            = 18
  settings     = jsonencode({ unit = "percent", y_axis_min = 0, y_axis_max = 100 })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(value_avg) * 100 AS value
      FROM
        {{source}}
      WHERE
        dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'up'
      GROUP BY
        time
      ORDER BY
        time
    SQL
  }
}

resource "logtail_dashboard_chart" "otel_gateway_scrape_duration" {
  dashboard_id = logtail_dashboard.otel_gateway.id
  name         = "Scrape Duration"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 6
  y            = 18
  settings     = jsonencode({ unit = "s" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(value_avg) AS value
      FROM
        {{source}}
      WHERE
        dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'scrape_duration_seconds'
      GROUP BY
        time
      ORDER BY
        time
    SQL
  }
}

resource "logtail_dashboard_chart" "otel_gateway_pod_table_size" {
  dashboard_id = logtail_dashboard.otel_gateway.id
  name         = "K8s Pod Table Size"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 0
  y            = 26
  settings     = jsonencode({ unit = "shortened" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(value_avg) AS value
      FROM
        {{source}}
      WHERE
        dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'otelcol_otelsvc_k8s_pod_table_size'
      GROUP BY
        time
      ORDER BY
        time
    SQL
  }
}

resource "logtail_dashboard_chart" "otel_gateway_memory_rss" {
  dashboard_id = logtail_dashboard.otel_gateway.id
  name         = "Memory RSS"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 6
  y            = 26
  settings     = jsonencode({ unit = "B_iec" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(value_avg) AS value
      FROM
        {{source}}
      WHERE
        dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'otelcol_process_memory_rss'
      GROUP BY
        time
      ORDER BY
        time
    SQL
  }
}

# ── Cilium / Hubble ───────────────────────────────────────────────────────────
# Cilium operator metrics are available now. Hubble flow metrics (hubble_flows_*,
# hubble_drop_*, hubble_http_*, hubble_tcp_*) will populate once the Cilium
# DaemonSet rolls out with hubble.metrics.enabled (pushed in the same commit
# as this file — Terraform Cloud apply in progress).

resource "logtail_dashboard" "cilium" {
  name               = "Cilium / Hubble"
  dashboard_group_id = logtail_dashboard_group.observability.id
  date_range_from    = "now-3h"
  date_range_to      = "now"

  variable {
    name          = "source"
    variable_type = "source"
    values        = [logtail_source.otel_collector.id]
  }
}

resource "logtail_dashboard_section" "cilium_health" {
  dashboard_id = logtail_dashboard.cilium.id
  name         = "Cilium Health"
  y            = 0
}

resource "logtail_dashboard_chart" "cilium_hive_status" {
  dashboard_id = logtail_dashboard.cilium.id
  name         = "Hive Status"
  chart_type   = "number_chart"
  w            = 4
  h            = 8
  x            = 0
  y            = 1
  settings     = jsonencode({ unit = "none", decimal_places = 0 })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        avgMerge(value_avg) AS value
      FROM
        {{source}}
      WHERE
        dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'cilium_hive_status'
    SQL
  }
}

resource "logtail_dashboard_chart" "cilium_operator_errors" {
  dashboard_id = logtail_dashboard.cilium.id
  name         = "Operator Errors & Warnings/s"
  chart_type   = "line_chart"
  w            = 4
  h            = 8
  x            = 4
  y            = 1
  settings     = jsonencode({ unit = "rps", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(rate_avg) AS value
      FROM
        {{source}}
      WHERE
        dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'cilium_operator_errors_warnings_total'
      GROUP BY
        time
      ORDER BY
        time
    SQL
  }
}

resource "logtail_dashboard_chart" "cilium_lb_unsatisfied" {
  dashboard_id = logtail_dashboard.cilium.id
  name         = "LB Services Without IPs"
  chart_type   = "line_chart"
  w            = 4
  h            = 8
  x            = 8
  y            = 1
  settings     = jsonencode({ unit = "shortened", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(value_avg) AS value
      FROM
        {{source}}
      WHERE
        dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'cilium_operator_lbipam_services_unsatisfied_total'
      GROUP BY
        time
      ORDER BY
        time
    SQL
  }
}

resource "logtail_dashboard_section" "cilium_lb" {
  dashboard_id = logtail_dashboard.cilium.id
  name         = "Load Balancer"
  y            = 9
}

resource "logtail_dashboard_chart" "cilium_lb_matching" {
  dashboard_id = logtail_dashboard.cilium.id
  name         = "LB Services Matching Pools"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 0
  y            = 10
  settings     = jsonencode({ unit = "shortened" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(value_avg) AS value
      FROM
        {{source}}
      WHERE
        dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'cilium_operator_lbipam_services_matching_total'
      GROUP BY
        time
      ORDER BY
        time
    SQL
  }
}

resource "logtail_dashboard_chart" "cilium_lb_conflicting" {
  dashboard_id = logtail_dashboard.cilium.id
  name         = "Conflicting LB Pools"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 6
  y            = 10
  settings     = jsonencode({ unit = "shortened", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(value_avg) AS value
      FROM
        {{source}}
      WHERE
        dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'cilium_operator_lbipam_conflicting_pools_total'
      GROUP BY
        time
      ORDER BY
        time
    SQL
  }
}

resource "logtail_dashboard_section" "cilium_identity" {
  dashboard_id = logtail_dashboard.cilium.id
  name         = "Identity Management"
  y            = 18
}

resource "logtail_dashboard_chart" "cilium_identity_gc_entries" {
  dashboard_id = logtail_dashboard.cilium.id
  name         = "Identity GC Entries"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 0
  y            = 19
  settings     = jsonencode({ unit = "shortened" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(value_avg) AS value
      FROM
        {{source}}
      WHERE
        dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'cilium_operator_identity_gc_entries'
      GROUP BY
        time
      ORDER BY
        time
    SQL
  }
}

resource "logtail_dashboard_chart" "cilium_identity_gc_runs" {
  dashboard_id = logtail_dashboard.cilium.id
  name         = "Identity GC Runs/s"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 6
  y            = 19
  settings     = jsonencode({ unit = "rps", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(rate_avg) AS value
      FROM
        {{source}}
      WHERE
        dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'cilium_operator_identity_gc_runs'
      GROUP BY
        time
      ORDER BY
        time
    SQL
  }
}

resource "logtail_dashboard_section" "cilium_hubble" {
  dashboard_id = logtail_dashboard.cilium.id
  name         = "Hubble Flow Metrics"
  y            = 27
}

resource "logtail_dashboard_chart" "cilium_hubble_pending" {
  dashboard_id = logtail_dashboard.cilium.id
  name         = "Hubble metrics pending rollout"
  chart_type   = "static_text_chart"
  w            = 12
  h            = 4
  x            = 0
  y            = 28
  query {
    query_type  = "static_text"
    static_text = "Hubble flow metrics (`hubble_flows_processed_total`, `hubble_drop_total`, `hubble_http_requests_total`, `hubble_tcp_flags_total`) will appear here once the Cilium DaemonSet finishes rolling out with `hubble.metrics.enabled`. Charts for drops-by-reason, flow rate, and HTTP error rate will be added once the metrics are confirmed flowing."
  }
}
