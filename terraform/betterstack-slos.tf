# Better Stack SLO dashboards — willpxxr-live cluster.
#
# Each dashboard tracks one SLI (good events / total events) vs a fixed target.
# Label filtering uses label('key') against the tags Map — confirmed present in raw data.
#
# SLI definitions:
#   Envoy Gateway:  non-5xx / total on http-10080 listener           target: 99.5%
#   OTEL Pipeline:  accepted metric points / (accepted + failed)      target: 99.9%
#   Flux:           (reconciles − errors) / reconciles  [flux-system] target: 99.9%
#   cert-manager:   (reconciles − errors) / reconciles  [cert-manager] target: 99.9%
#   Cilium:         (flows − drops) / flows                           target: 99.5%

resource "logtail_dashboard_group" "slos" {
  name = "SLOs"
}

# ══════════════════════════════════════════════════════════════════════════════
# Envoy Gateway — HTTP Availability SLO (99.5%)
# Good event: any downstream request on http-10080 that returns a non-5xx.
# Bad event:  any downstream request on http-10080 that returns a 5xx.
# 4xx are intentionally not counted as bad — Auth0 redirects/401s are normal.
# ══════════════════════════════════════════════════════════════════════════════

resource "logtail_dashboard" "slo_envoy" {
  name               = "SLO — Envoy Gateway HTTP"
  dashboard_group_id = logtail_dashboard_group.slos.id
  date_range_from    = "now-24h"
  date_range_to      = "now"

  variable {
    name          = "source"
    variable_type = "source"
    values        = [logtail_source.otel_collector.id]
  }
}

resource "logtail_dashboard_section" "slo_envoy_sli" {
  dashboard_id = logtail_dashboard.slo_envoy.id
  name         = "SLI vs Target"
  y            = 0
}

resource "logtail_dashboard_chart" "slo_envoy_current" {
  dashboard_id = logtail_dashboard.slo_envoy.id
  name         = "Current HTTP Success Rate"
  chart_type   = "number_chart"
  w            = 4
  h            = 8
  x            = 0
  y            = 1
  settings     = jsonencode({ unit = "percent", decimal_places = 2 })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        avgMergeIf(rate_avg, label('envoy_http_conn_manager_prefix') = 'http-10080'
          AND label('envoy_response_code_class') != '5') /
        nullIf(avgMergeIf(rate_avg, label('envoy_http_conn_manager_prefix') = 'http-10080'), 0)
          AS "Success Rate"
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'envoy_http_downstream_rq_xx'
    SQL
  }
}

resource "logtail_dashboard_chart" "slo_envoy_trend" {
  dashboard_id = logtail_dashboard.slo_envoy.id
  name         = "HTTP Success Rate vs Target"
  chart_type   = "line_chart"
  w            = 8
  h            = 8
  x            = 4
  y            = 1
  settings = jsonencode({
    unit          = "percent"
    y_axis_min    = 0.9
    y_axis_max    = 1
    value_columns = ["SLI", "Target (99.5%)"]
    legend        = "shown_below_with_statistics"
  })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMergeIf(rate_avg, label('envoy_http_conn_manager_prefix') = 'http-10080'
          AND label('envoy_response_code_class') != '5') /
        nullIf(avgMergeIf(rate_avg, label('envoy_http_conn_manager_prefix') = 'http-10080'), 0)
          AS "SLI",
        0.995 AS "Target (99.5%)"
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'envoy_http_downstream_rq_xx'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_section" "slo_envoy_events" {
  dashboard_id = logtail_dashboard.slo_envoy.id
  name         = "Events"
  y            = 9
}

resource "logtail_dashboard_chart" "slo_envoy_good_rate" {
  dashboard_id = logtail_dashboard.slo_envoy.id
  name         = "Good Requests /s (non-5xx on http-10080)"
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
        avgMergeIf(rate_avg, label('envoy_http_conn_manager_prefix') = 'http-10080'
          AND label('envoy_response_code_class') != '5') AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'envoy_http_downstream_rq_xx'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_chart" "slo_envoy_bad_rate" {
  dashboard_id = logtail_dashboard.slo_envoy.id
  name         = "Bad Requests /s (5xx on http-10080)"
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
        avgMergeIf(rate_avg, label('envoy_http_conn_manager_prefix') = 'http-10080'
          AND label('envoy_response_code_class') = '5') AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'envoy_http_downstream_rq_xx'
      GROUP BY time ORDER BY time
    SQL
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# OTEL Pipeline — Telemetry Delivery SLO (99.9%)
# Good event:  metric point accepted by the receiver.
# Bad event:   metric point refused or failed.
# ══════════════════════════════════════════════════════════════════════════════

resource "logtail_dashboard" "slo_otel" {
  name               = "SLO — OTEL Telemetry Delivery"
  dashboard_group_id = logtail_dashboard_group.slos.id
  date_range_from    = "now-24h"
  date_range_to      = "now"

  variable {
    name          = "source"
    variable_type = "source"
    values        = [logtail_source.otel_collector.id]
  }
}

resource "logtail_dashboard_section" "slo_otel_sli" {
  dashboard_id = logtail_dashboard.slo_otel.id
  name         = "SLI vs Target"
  y            = 0
}

resource "logtail_dashboard_chart" "slo_otel_current" {
  dashboard_id = logtail_dashboard.slo_otel.id
  name         = "Current Delivery Rate"
  chart_type   = "number_chart"
  w            = 4
  h            = 8
  x            = 0
  y            = 1
  settings     = jsonencode({ unit = "percent", decimal_places = 2 })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        avgMergeIf(rate_avg, name = 'otelcol_receiver_accepted_metric_points') /
        nullIf(
          avgMergeIf(rate_avg, name = 'otelcol_receiver_accepted_metric_points') +
          avgMergeIf(rate_avg, name = 'otelcol_receiver_failed_metric_points'),
          0
        ) AS "Delivery Rate"
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name IN ('otelcol_receiver_accepted_metric_points', 'otelcol_receiver_failed_metric_points')
    SQL
  }
}

resource "logtail_dashboard_chart" "slo_otel_trend" {
  dashboard_id = logtail_dashboard.slo_otel.id
  name         = "Metric Delivery Rate vs Target"
  chart_type   = "line_chart"
  w            = 8
  h            = 8
  x            = 4
  y            = 1
  settings = jsonencode({
    unit          = "percent"
    y_axis_min    = 0.9
    y_axis_max    = 1
    value_columns = ["SLI", "Target (99.9%)"]
    legend        = "shown_below_with_statistics"
  })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        avgMergeIf(rate_avg, name = 'otelcol_receiver_accepted_metric_points') /
        nullIf(
          avgMergeIf(rate_avg, name = 'otelcol_receiver_accepted_metric_points') +
          avgMergeIf(rate_avg, name = 'otelcol_receiver_failed_metric_points'),
          0
        ) AS "SLI",
        0.999 AS "Target (99.9%)"
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name IN ('otelcol_receiver_accepted_metric_points', 'otelcol_receiver_failed_metric_points')
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_section" "slo_otel_events" {
  dashboard_id = logtail_dashboard.slo_otel.id
  name         = "Events"
  y            = 9
}

resource "logtail_dashboard_chart" "slo_otel_good_rate" {
  dashboard_id = logtail_dashboard.slo_otel.id
  name         = "Accepted Metric Points /s"
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
        AND name = 'otelcol_receiver_accepted_metric_points'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_chart" "slo_otel_bad_rate" {
  dashboard_id = logtail_dashboard.slo_otel.id
  name         = "Failed Metric Points /s"
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
        AND name = 'otelcol_receiver_failed_metric_points'
      GROUP BY time ORDER BY time
    SQL
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# Flux — Reconciliation SLO (99.9%)
# Good event:  reconcile that succeeds (controller_runtime_reconcile_total minus errors).
# Bad event:   reconcile that errors (controller_runtime_reconcile_errors_total).
# Scoped to flux-system namespace to exclude cert-manager and envoy-gateway.
# ══════════════════════════════════════════════════════════════════════════════

resource "logtail_dashboard" "slo_flux" {
  name               = "SLO — Flux Reconciliation"
  dashboard_group_id = logtail_dashboard_group.slos.id
  date_range_from    = "now-24h"
  date_range_to      = "now"

  variable {
    name          = "source"
    variable_type = "source"
    values        = [logtail_source.otel_collector.id]
  }
}

resource "logtail_dashboard_section" "slo_flux_sli" {
  dashboard_id = logtail_dashboard.slo_flux.id
  name         = "SLI vs Target"
  y            = 0
}

resource "logtail_dashboard_chart" "slo_flux_current" {
  dashboard_id = logtail_dashboard.slo_flux.id
  name         = "Current Reconciliation Success Rate"
  chart_type   = "number_chart"
  w            = 4
  h            = 8
  x            = 0
  y            = 1
  settings     = jsonencode({ unit = "percent", decimal_places = 2 })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        (
          avgMergeIf(rate_avg, name = 'controller_runtime_reconcile_total'
            AND label('k8s.namespace.name') = 'flux-system') -
          avgMergeIf(rate_avg, name = 'controller_runtime_reconcile_errors_total'
            AND label('k8s.namespace.name') = 'flux-system')
        ) /
        nullIf(avgMergeIf(rate_avg, name = 'controller_runtime_reconcile_total'
          AND label('k8s.namespace.name') = 'flux-system'), 0) AS "Success Rate"
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name IN ('controller_runtime_reconcile_total', 'controller_runtime_reconcile_errors_total')
    SQL
  }
}

resource "logtail_dashboard_chart" "slo_flux_trend" {
  dashboard_id = logtail_dashboard.slo_flux.id
  name         = "Reconciliation Success Rate vs Target"
  chart_type   = "line_chart"
  w            = 8
  h            = 8
  x            = 4
  y            = 1
  settings = jsonencode({
    unit          = "percent"
    y_axis_min    = 0.9
    y_axis_max    = 1
    value_columns = ["SLI", "Target (99.9%)"]
    legend        = "shown_below_with_statistics"
  })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        (
          avgMergeIf(rate_avg, name = 'controller_runtime_reconcile_total'
            AND label('k8s.namespace.name') = 'flux-system') -
          avgMergeIf(rate_avg, name = 'controller_runtime_reconcile_errors_total'
            AND label('k8s.namespace.name') = 'flux-system')
        ) /
        nullIf(avgMergeIf(rate_avg, name = 'controller_runtime_reconcile_total'
          AND label('k8s.namespace.name') = 'flux-system'), 0) AS "SLI",
        0.999 AS "Target (99.9%)"
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name IN ('controller_runtime_reconcile_total', 'controller_runtime_reconcile_errors_total')
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_section" "slo_flux_events" {
  dashboard_id = logtail_dashboard.slo_flux.id
  name         = "Events"
  y            = 9
}

resource "logtail_dashboard_chart" "slo_flux_good_rate" {
  dashboard_id = logtail_dashboard.slo_flux.id
  name         = "Successful Reconciles /s"
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
        avgMergeIf(rate_avg, label('k8s.namespace.name') = 'flux-system') AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'controller_runtime_reconcile_total'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_chart" "slo_flux_bad_rate" {
  dashboard_id = logtail_dashboard.slo_flux.id
  name         = "Reconcile Errors /s"
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
        avgMergeIf(rate_avg, label('k8s.namespace.name') = 'flux-system') AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'controller_runtime_reconcile_errors_total'
      GROUP BY time ORDER BY time
    SQL
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# cert-manager — Reconciliation SLO (99.9%)
# Same pattern as Flux, scoped to cert-manager namespace.
# ══════════════════════════════════════════════════════════════════════════════

resource "logtail_dashboard" "slo_cert_manager" {
  name               = "SLO — cert-manager Reconciliation"
  dashboard_group_id = logtail_dashboard_group.slos.id
  date_range_from    = "now-24h"
  date_range_to      = "now"

  variable {
    name          = "source"
    variable_type = "source"
    values        = [logtail_source.otel_collector.id]
  }
}

resource "logtail_dashboard_section" "slo_cert_manager_sli" {
  dashboard_id = logtail_dashboard.slo_cert_manager.id
  name         = "SLI vs Target"
  y            = 0
}

resource "logtail_dashboard_chart" "slo_cert_manager_current" {
  dashboard_id = logtail_dashboard.slo_cert_manager.id
  name         = "Current Reconciliation Success Rate"
  chart_type   = "number_chart"
  w            = 4
  h            = 8
  x            = 0
  y            = 1
  settings     = jsonencode({ unit = "percent", decimal_places = 2 })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        (
          avgMergeIf(rate_avg, name = 'controller_runtime_reconcile_total'
            AND label('k8s.namespace.name') = 'cert-manager') -
          avgMergeIf(rate_avg, name = 'controller_runtime_reconcile_errors_total'
            AND label('k8s.namespace.name') = 'cert-manager')
        ) /
        nullIf(avgMergeIf(rate_avg, name = 'controller_runtime_reconcile_total'
          AND label('k8s.namespace.name') = 'cert-manager'), 0) AS "Success Rate"
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name IN ('controller_runtime_reconcile_total', 'controller_runtime_reconcile_errors_total')
    SQL
  }
}

resource "logtail_dashboard_chart" "slo_cert_manager_trend" {
  dashboard_id = logtail_dashboard.slo_cert_manager.id
  name         = "Reconciliation Success Rate vs Target"
  chart_type   = "line_chart"
  w            = 8
  h            = 8
  x            = 4
  y            = 1
  settings = jsonencode({
    unit          = "percent"
    y_axis_min    = 0.9
    y_axis_max    = 1
    value_columns = ["SLI", "Target (99.9%)"]
    legend        = "shown_below_with_statistics"
  })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        (
          avgMergeIf(rate_avg, name = 'controller_runtime_reconcile_total'
            AND label('k8s.namespace.name') = 'cert-manager') -
          avgMergeIf(rate_avg, name = 'controller_runtime_reconcile_errors_total'
            AND label('k8s.namespace.name') = 'cert-manager')
        ) /
        nullIf(avgMergeIf(rate_avg, name = 'controller_runtime_reconcile_total'
          AND label('k8s.namespace.name') = 'cert-manager'), 0) AS "SLI",
        0.999 AS "Target (99.9%)"
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name IN ('controller_runtime_reconcile_total', 'controller_runtime_reconcile_errors_total')
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_section" "slo_cert_manager_events" {
  dashboard_id = logtail_dashboard.slo_cert_manager.id
  name         = "Events"
  y            = 9
}

resource "logtail_dashboard_chart" "slo_cert_manager_good_rate" {
  dashboard_id = logtail_dashboard.slo_cert_manager.id
  name         = "Successful Reconciles /s"
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
        avgMergeIf(rate_avg, label('k8s.namespace.name') = 'cert-manager') AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'controller_runtime_reconcile_total'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_chart" "slo_cert_manager_bad_rate" {
  dashboard_id = logtail_dashboard.slo_cert_manager.id
  name         = "Reconcile Errors /s"
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
        avgMergeIf(rate_avg, label('k8s.namespace.name') = 'cert-manager') AS value
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name = 'controller_runtime_reconcile_errors_total'
      GROUP BY time ORDER BY time
    SQL
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# Cilium — Network Flow SLO (99.5%)
# Good event:  network flow that was forwarded (hubble_flows_processed_total − drops).
# Bad event:   network flow that was dropped (hubble_drop_total).
# ══════════════════════════════════════════════════════════════════════════════

resource "logtail_dashboard" "slo_cilium" {
  name               = "SLO — Cilium Network Flow"
  dashboard_group_id = logtail_dashboard_group.slos.id
  date_range_from    = "now-24h"
  date_range_to      = "now"

  variable {
    name          = "source"
    variable_type = "source"
    values        = [logtail_source.otel_collector.id]
  }
}

resource "logtail_dashboard_section" "slo_cilium_sli" {
  dashboard_id = logtail_dashboard.slo_cilium.id
  name         = "SLI vs Target"
  y            = 0
}

resource "logtail_dashboard_chart" "slo_cilium_current" {
  dashboard_id = logtail_dashboard.slo_cilium.id
  name         = "Current Flow Forward Rate"
  chart_type   = "number_chart"
  w            = 4
  h            = 8
  x            = 0
  y            = 1
  settings     = jsonencode({ unit = "percent", decimal_places = 2 })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        (
          avgMergeIf(rate_avg, name = 'hubble_flows_processed_total') -
          avgMergeIf(rate_avg, name = 'hubble_drop_total')
        ) /
        nullIf(avgMergeIf(rate_avg, name = 'hubble_flows_processed_total'), 0)
          AS "Forward Rate"
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name IN ('hubble_flows_processed_total', 'hubble_drop_total')
    SQL
  }
}

resource "logtail_dashboard_chart" "slo_cilium_trend" {
  dashboard_id = logtail_dashboard.slo_cilium.id
  name         = "Network Flow Forward Rate vs Target"
  chart_type   = "line_chart"
  w            = 8
  h            = 8
  x            = 4
  y            = 1
  settings = jsonencode({
    unit          = "percent"
    y_axis_min    = 0.9
    y_axis_max    = 1
    value_columns = ["SLI", "Target (99.5%)"]
    legend        = "shown_below_with_statistics"
  })
  query {
    query_type = "sql_expression"
    sql_query  = <<-SQL
      SELECT
        {{time}} AS time,
        (
          avgMergeIf(rate_avg, name = 'hubble_flows_processed_total') -
          avgMergeIf(rate_avg, name = 'hubble_drop_total')
        ) /
        nullIf(avgMergeIf(rate_avg, name = 'hubble_flows_processed_total'), 0) AS "SLI",
        0.995 AS "Target (99.5%)"
      FROM {{source}}
      WHERE dt BETWEEN {{start_time}} AND {{end_time}}
        AND name IN ('hubble_flows_processed_total', 'hubble_drop_total')
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_section" "slo_cilium_events" {
  dashboard_id = logtail_dashboard.slo_cilium.id
  name         = "Events"
  y            = 9
}

resource "logtail_dashboard_chart" "slo_cilium_good_rate" {
  dashboard_id = logtail_dashboard.slo_cilium.id
  name         = "Forwarded Flows /s"
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
        AND name = 'hubble_flows_processed_total'
      GROUP BY time ORDER BY time
    SQL
  }
}

resource "logtail_dashboard_chart" "slo_cilium_bad_rate" {
  dashboard_id = logtail_dashboard.slo_cilium.id
  name         = "Dropped Flows /s"
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
        AND name = 'hubble_drop_total'
      GROUP BY time ORDER BY time
    SQL
  }
}
