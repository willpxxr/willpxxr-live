# Better Stack dashboards — willpxxr-live cluster.
# Golden signals (traffic, errors, latency, saturation) per service + infrastructure.
# Source: logtail_source.otel_collector (willpxxr-live-otel-collector).

# ── Dashboard groups ──────────────────────────────────────────────────────────

resource "logtail_dashboard_group" "observability" {
  name = "Observability"
}

resource "logtail_dashboard_group" "services" {
  name = "Services"
}

resource "logtail_dashboard_group" "infrastructure" {
  name = "Infrastructure"
}

# ══════════════════════════════════════════════════════════════════════════════
# OTEL Collector — Agent
# DaemonSet: filelog (container logs), host metrics, kubelet stats.
# SLIs: log ingestion success/failure, export queue saturation, processor drop.
# ══════════════════════════════════════════════════════════════════════════════

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

resource "logtail_dashboard_section" "otel_agent_pipeline" {
  dashboard_id = logtail_dashboard.otel_agent.id
  name         = "Log Pipeline"
  y            = 0
}

resource "logtail_dashboard_chart" "otel_agent_log_ingestion" {
  dashboard_id = logtail_dashboard.otel_agent.id
  name         = "Log Records Received vs Failed /s"
  chart_type   = "line_chart"
  w            = 8
  h            = 8
  x            = 0
  y            = 1
  settings     = jsonencode({ unit = "rps", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMergeIf(rate_avg, name = 'otelcol_receiver_accepted_log_records') AS received,
        avgMergeIf(rate_avg, name = 'otelcol_receiver_failed_log_records')   AS failed
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name IN ('otelcol_receiver_accepted_log_records', 'otelcol_receiver_failed_log_records')
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_chart" "otel_agent_export_queue" {
  dashboard_id = logtail_dashboard.otel_agent.id
  name         = "Export Queue Utilisation"
  chart_type   = "line_chart"
  w            = 4
  h            = 8
  x            = 8
  y            = 1
  settings     = jsonencode({ unit = "percent", y_axis_min = 0, y_axis_max = 100, treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMergeIf(value_avg, name = 'otelcol_exporter_queue_size') /
        nullIf(avgMergeIf(value_avg, name = 'otelcol_exporter_queue_capacity'), 0) * 100 AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name IN ('otelcol_exporter_queue_size', 'otelcol_exporter_queue_capacity')
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_section" "otel_agent_processor" {
  dashboard_id = logtail_dashboard.otel_agent.id
  name         = "Processor"
  y            = 9
}

resource "logtail_dashboard_chart" "otel_agent_processor_throughput" {
  dashboard_id = logtail_dashboard.otel_agent.id
  name         = "Processor Incoming vs Outgoing /s"
  chart_type   = "line_chart"
  w            = 8
  h            = 8
  x            = 0
  y            = 10
  settings     = jsonencode({ unit = "rps", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMergeIf(rate_avg, name = 'otelcol_processor_incoming_items') AS incoming,
        avgMergeIf(rate_avg, name = 'otelcol_processor_outgoing_items') AS outgoing
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name IN ('otelcol_processor_incoming_items', 'otelcol_processor_outgoing_items')
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_chart" "otel_agent_memory" {
  dashboard_id = logtail_dashboard.otel_agent.id
  name         = "Memory RSS"
  chart_type   = "line_chart"
  w            = 4
  h            = 8
  x            = 8
  y            = 10
  settings     = jsonencode({ unit = "B_iec" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(value_avg) AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'otelcol_process_memory_rss'
      GROUP BY time ORDER BY time
    SQL
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# OTEL Collector — Gateway
# Deployment: k8s_cluster receiver, Prometheus scraping, OTLP traces from Envoy.
# SLIs: metric ingestion success/failure, export queue, scrape targets up.
# ══════════════════════════════════════════════════════════════════════════════

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

resource "logtail_dashboard_section" "otel_gateway_pipeline" {
  dashboard_id = logtail_dashboard.otel_gateway.id
  name         = "Metrics Pipeline"
  y            = 0
}

resource "logtail_dashboard_chart" "otel_gateway_metric_ingestion" {
  dashboard_id = logtail_dashboard.otel_gateway.id
  name         = "Metric Points Received vs Failed /s"
  chart_type   = "line_chart"
  w            = 8
  h            = 8
  x            = 0
  y            = 1
  settings     = jsonencode({ unit = "rps", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMergeIf(rate_avg, name = 'otelcol_receiver_accepted_metric_points') AS received,
        avgMergeIf(rate_avg, name = 'otelcol_receiver_failed_metric_points')   AS failed
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name IN ('otelcol_receiver_accepted_metric_points', 'otelcol_receiver_failed_metric_points')
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_chart" "otel_gateway_export_queue" {
  dashboard_id = logtail_dashboard.otel_gateway.id
  name         = "Export Queue Utilisation"
  chart_type   = "line_chart"
  w            = 4
  h            = 8
  x            = 8
  y            = 1
  settings     = jsonencode({ unit = "percent", y_axis_min = 0, y_axis_max = 100, treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMergeIf(value_avg, name = 'otelcol_exporter_queue_size') /
        nullIf(avgMergeIf(value_avg, name = 'otelcol_exporter_queue_capacity'), 0) * 100 AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name IN ('otelcol_exporter_queue_size', 'otelcol_exporter_queue_capacity')
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_section" "otel_gateway_scrape" {
  dashboard_id = logtail_dashboard.otel_gateway.id
  name         = "Prometheus Scrape Health"
  y            = 9
}

resource "logtail_dashboard_chart" "otel_gateway_targets_up" {
  dashboard_id = logtail_dashboard.otel_gateway.id
  name         = "Scrape Targets Up %"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 0
  y            = 10
  settings     = jsonencode({ unit = "percent", y_axis_min = 0, y_axis_max = 100 })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(value_avg) * 100 AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'up'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_chart" "otel_gateway_scrape_errors" {
  dashboard_id = logtail_dashboard.otel_gateway.id
  name         = "Scraper Errored Metric Points /s"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 6
  y            = 10
  settings     = jsonencode({ unit = "rps", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(rate_avg) AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'otelcol_scraper_errored_metric_points'
      GROUP BY time ORDER BY time
    SQL
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# Cilium / Hubble
# SLIs: network drop rate (key symptom of policy violations), flow volume,
#        Cilium operator health.
# ══════════════════════════════════════════════════════════════════════════════

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

resource "logtail_dashboard_section" "cilium_network" {
  dashboard_id = logtail_dashboard.cilium.id
  name         = "Network (Hubble)"
  y            = 0
}

resource "logtail_dashboard_chart" "cilium_drop_rate" {
  dashboard_id = logtail_dashboard.cilium.id
  name         = "Network Drop Rate /s"
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
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'hubble_drop_total'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_chart" "cilium_flows_rate" {
  dashboard_id = logtail_dashboard.cilium.id
  name         = "Flows Processed /s"
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
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'hubble_flows_processed_total'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_section" "cilium_operator" {
  dashboard_id = logtail_dashboard.cilium.id
  name         = "Cilium Operator"
  y            = 9
}

resource "logtail_dashboard_chart" "cilium_operator_errors" {
  dashboard_id = logtail_dashboard.cilium.id
  name         = "Operator Errors & Warnings /s"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 0
  y            = 10
  settings     = jsonencode({ unit = "rps", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(rate_avg) AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'cilium_operator_errors_warnings_total'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_chart" "cilium_lb_unsatisfied" {
  dashboard_id = logtail_dashboard.cilium.id
  name         = "LB Services Without IPs"
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
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'cilium_operator_lbipam_services_unsatisfied_total'
      GROUP BY time ORDER BY time
    SQL
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# Envoy Gateway
# SLIs: downstream request rate, upstream timeouts, upstream connection failures,
#        active connections (saturation), SSL handshake errors.
# ══════════════════════════════════════════════════════════════════════════════

resource "logtail_dashboard" "envoy_gateway" {
  name               = "Envoy Gateway"
  dashboard_group_id = logtail_dashboard_group.services.id
  date_range_from    = "now-3h"
  date_range_to      = "now"

  variable {
    name          = "source"
    variable_type = "source"
    values        = [logtail_source.otel_collector.id]
  }
}

resource "logtail_dashboard_section" "envoy_traffic" {
  dashboard_id = logtail_dashboard.envoy_gateway.id
  name         = "Traffic"
  y            = 0
}

resource "logtail_dashboard_chart" "envoy_downstream_rps" {
  dashboard_id = logtail_dashboard.envoy_gateway.id
  name         = "Downstream Requests /s (all status classes)"
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
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'envoy_http_downstream_rq_xx'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_chart" "envoy_upstream_rps" {
  dashboard_id = logtail_dashboard.envoy_gateway.id
  name         = "Upstream Requests /s"
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
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'envoy_cluster_upstream_rq_total'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_section" "envoy_errors" {
  dashboard_id = logtail_dashboard.envoy_gateway.id
  name         = "Errors"
  y            = 9
}

resource "logtail_dashboard_chart" "envoy_upstream_timeouts" {
  dashboard_id = logtail_dashboard.envoy_gateway.id
  name         = "Upstream Timeouts /s"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 0
  y            = 10
  settings     = jsonencode({ unit = "rps", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(rate_avg) AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'envoy_cluster_upstream_rq_timeout'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_chart" "envoy_upstream_cx_fail" {
  dashboard_id = logtail_dashboard.envoy_gateway.id
  name         = "Upstream Connection Failures /s"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 6
  y            = 10
  settings     = jsonencode({ unit = "rps", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(rate_avg) AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'envoy_cluster_upstream_cx_connect_fail'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_section" "envoy_saturation" {
  dashboard_id = logtail_dashboard.envoy_gateway.id
  name         = "Saturation"
  y            = 18
}

resource "logtail_dashboard_chart" "envoy_upstream_cx_active" {
  dashboard_id = logtail_dashboard.envoy_gateway.id
  name         = "Active Upstream Connections"
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
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'envoy_cluster_upstream_cx_active'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_chart" "envoy_upstream_rq_active" {
  dashboard_id = logtail_dashboard.envoy_gateway.id
  name         = "Active Upstream Requests"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 6
  y            = 19
  settings     = jsonencode({ unit = "shortened" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(value_avg) AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'envoy_cluster_upstream_rq_active'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_section" "envoy_tls" {
  dashboard_id = logtail_dashboard.envoy_gateway.id
  name         = "TLS"
  y            = 27
}

resource "logtail_dashboard_chart" "envoy_ssl_handshakes" {
  dashboard_id = logtail_dashboard.envoy_gateway.id
  name         = "SSL Handshakes /s"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 0
  y            = 28
  settings     = jsonencode({ unit = "rps", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(rate_avg) AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'envoy_cluster_ssl_handshake'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_chart" "envoy_ssl_errors" {
  dashboard_id = logtail_dashboard.envoy_gateway.id
  name         = "SSL Connection Errors /s"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 6
  y            = 28
  settings     = jsonencode({ unit = "rps", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(rate_avg) AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'envoy_cluster_ssl_connection_error'
      GROUP BY time ORDER BY time
    SQL
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# cert-manager
# SLIs: controller sync activity, reconcile errors.
# ══════════════════════════════════════════════════════════════════════════════

resource "logtail_dashboard" "cert_manager" {
  name               = "cert-manager"
  dashboard_group_id = logtail_dashboard_group.services.id
  date_range_from    = "now-3h"
  date_range_to      = "now"

  variable {
    name          = "source"
    variable_type = "source"
    values        = [logtail_source.otel_collector.id]
  }
}

resource "logtail_dashboard_section" "cert_manager_reconcile" {
  dashboard_id = logtail_dashboard.cert_manager.id
  name         = "Reconciliation"
  y            = 0
}

resource "logtail_dashboard_chart" "cert_manager_sync_rate" {
  dashboard_id = logtail_dashboard.cert_manager.id
  name         = "Controller Sync Calls /s"
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
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'certmanager_controller_sync_call_count'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_chart" "cert_manager_reconcile_errors" {
  dashboard_id = logtail_dashboard.cert_manager.id
  name         = "Reconcile Errors /s"
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
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'controller_runtime_reconcile_errors_total'
      GROUP BY time ORDER BY time
    SQL
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# Flux
# SLIs: resource health ratio, reconcile errors, workqueue depth (backlog).
# ══════════════════════════════════════════════════════════════════════════════

resource "logtail_dashboard" "flux" {
  name               = "Flux"
  dashboard_group_id = logtail_dashboard_group.services.id
  date_range_from    = "now-3h"
  date_range_to      = "now"

  variable {
    name          = "source"
    variable_type = "source"
    values        = [logtail_source.otel_collector.id]
  }
}

resource "logtail_dashboard_section" "flux_health" {
  dashboard_id = logtail_dashboard.flux.id
  name         = "GitOps Health"
  y            = 0
}

resource "logtail_dashboard_chart" "flux_resource_health" {
  dashboard_id = logtail_dashboard.flux.id
  name         = "Resource Health Ratio (1.0 = all ready)"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 0
  y            = 1
  settings     = jsonencode({ unit = "none", y_axis_min = 0, y_axis_max = 1 })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(value_avg) AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'flux_resource_info'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_chart" "flux_reconcile_errors" {
  dashboard_id = logtail_dashboard.flux.id
  name         = "Reconcile Errors /s"
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
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'gotk_reconcile_duration_seconds'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_section" "flux_queue" {
  dashboard_id = logtail_dashboard.flux.id
  name         = "Queue"
  y            = 9
}

resource "logtail_dashboard_chart" "flux_workqueue_depth" {
  dashboard_id = logtail_dashboard.flux.id
  name         = "Workqueue Depth (backlog)"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 0
  y            = 10
  settings     = jsonencode({ unit = "shortened", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(value_avg) AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'workqueue_depth'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_chart" "flux_workqueue_retries" {
  dashboard_id = logtail_dashboard.flux.id
  name         = "Workqueue Retries /s"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 6
  y            = 10
  settings     = jsonencode({ unit = "rps", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(rate_avg) AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'workqueue_retries_total'
      GROUP BY time ORDER BY time
    SQL
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# K8s — Nodes & Pods
# SLIs: container readiness, deployment availability gap, pod health,
#        CPU/memory usage, disk I/O.
# ══════════════════════════════════════════════════════════════════════════════

resource "logtail_dashboard" "k8s_nodes_pods" {
  name               = "K8s — Nodes & Pods"
  dashboard_group_id = logtail_dashboard_group.infrastructure.id
  date_range_from    = "now-3h"
  date_range_to      = "now"

  variable {
    name          = "source"
    variable_type = "source"
    values        = [logtail_source.otel_collector.id]
  }
}

resource "logtail_dashboard_section" "k8s_pod_health" {
  dashboard_id = logtail_dashboard.k8s_nodes_pods.id
  name         = "Pod Health"
  y            = 0
}

resource "logtail_dashboard_chart" "k8s_container_readiness" {
  dashboard_id = logtail_dashboard.k8s_nodes_pods.id
  name         = "Container Readiness (1.0 = all ready)"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 0
  y            = 1
  settings     = jsonencode({ unit = "none", y_axis_min = 0, y_axis_max = 1 })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(value_avg) AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'k8s.container.ready'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_chart" "k8s_deployment_gap" {
  dashboard_id = logtail_dashboard.k8s_nodes_pods.id
  name         = "Deployment Replicas Missing (desired − available)"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 6
  y            = 1
  settings     = jsonencode({ unit = "shortened", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMergeIf(value_avg, name = 'k8s.deployment.desired') -
        avgMergeIf(value_avg, name = 'k8s.deployment.available') AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name IN ('k8s.deployment.desired', 'k8s.deployment.available')
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_chart" "k8s_container_restarts" {
  dashboard_id = logtail_dashboard.k8s_nodes_pods.id
  name         = "Container Restarts (total)"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 0
  y            = 9
  settings     = jsonencode({ unit = "shortened", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(value_avg) AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'k8s.container.restarts'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_chart" "k8s_pod_network_errors" {
  dashboard_id = logtail_dashboard.k8s_nodes_pods.id
  name         = "Pod Network Errors /s"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 6
  y            = 9
  settings     = jsonencode({ unit = "rps", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(rate_avg) AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'k8s.pod.network.errors'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_section" "k8s_resource_usage" {
  dashboard_id = logtail_dashboard.k8s_nodes_pods.id
  name         = "Resource Usage"
  y            = 17
}

resource "logtail_dashboard_chart" "k8s_cpu_usage" {
  dashboard_id = logtail_dashboard.k8s_nodes_pods.id
  name         = "Container CPU Usage (total cores)"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 0
  y            = 18
  settings     = jsonencode({ unit = "none" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(value_avg) AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'container.cpu.usage'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_chart" "k8s_memory_working_set" {
  dashboard_id = logtail_dashboard.k8s_nodes_pods.id
  name         = "Container Memory Working Set"
  chart_type   = "line_chart"
  w            = 6
  h            = 8
  x            = 6
  y            = 18
  settings     = jsonencode({ unit = "B_iec" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(value_avg) AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'container.memory.working_set'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_chart" "k8s_disk_io" {
  dashboard_id = logtail_dashboard.k8s_nodes_pods.id
  name         = "Node Disk Operations /s"
  chart_type   = "line_chart"
  w            = 12
  h            = 8
  x            = 0
  y            = 26
  settings     = jsonencode({ unit = "rps", treat_missing_values = "zero" })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMerge(rate_avg) AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'system.disk.operations'
      GROUP BY time ORDER BY time
    SQL
  }
}
