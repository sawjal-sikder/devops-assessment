"""Validate live monitoring through Grafana's authenticated datasource proxies."""

import base64
import json
import os
import urllib.parse
import urllib.request
from pathlib import Path


def main():
    local = {}
    if Path(".env").exists():
        for line in Path(".env").read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                key, value = line.split("=", 1)
                local[key] = value
    user = os.getenv("GRAFANA_ADMIN_USER") or local["GRAFANA_ADMIN_USER"]
    password = os.getenv("GRAFANA_ADMIN_PASSWORD") or local["GRAFANA_ADMIN_PASSWORD"]
    auth = base64.b64encode(f"{user}:{password}".encode()).decode()
    base = os.getenv("GRAFANA_URL", "http://127.0.0.1:3000")

    def get(path, params=None):
        url = base + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        request = urllib.request.Request(url, headers={"Authorization": f"Basic {auth}"})
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)

    prom = "/api/datasources/proxy/uid/prometheus"
    loki = "/api/datasources/proxy/uid/loki"
    targets = get(prom + "/api/v1/targets")["data"]["activeTargets"]
    assert len(targets) == 6 and all(t["health"] == "up" for t in targets), targets
    print("Scrape targets: all 6 UP (app, node, cAdvisor, Prometheus, Loki, Alloy)")
    for path in sorted(Path("monitoring/grafana/dashboards").glob("*.json")):
        dashboard = json.loads(path.read_text())
        saved = get("/api/dashboards/uid/" + dashboard["uid"])
        assert saved["meta"]["provisioned"]
        for panel in dashboard["panels"]:
            if panel["type"] != "timeseries":
                continue
            for target in panel["targets"]:
                expression = target["expr"].replace("$__rate_interval", "1m")
                result = get(prom + "/api/v1/query", {"query": expression})
                assert result["status"] == "success", result
                assert result["data"]["result"], (dashboard["uid"], panel["title"])
        print(f"Dashboard {dashboard['title']}: provisioned; all metric queries return data")
    streams = get(loki + "/loki/api/v1/series", {"match[]": '{project="devops-monitoring"}'})
    services = {stream["service"] for stream in streams["data"]}
    expected = {"app", "prometheus", "grafana", "loki", "alloy", "node-exporter", "cadvisor"}
    assert expected.issubset(services), services
    print("Loki: logs present from all 7 stack containers")
    result = get(
        loki + "/loki/api/v1/query_range",
        {
            "query": '{project="devops-monitoring",service="app",level="INFO"} | json | status_code >= 400',
            "limit": "5",
        },
    )
    assert result["data"]["result"], "Generate demo errors first with monitoring_traffic.py"
    print("Loki: app JSON level label and numeric status-code filters verified")
    rules = get(prom + "/api/v1/rules")["data"]["groups"]
    alert_rules = [r for group in rules for r in group["rules"] if r["type"] == "alerting"]
    assert len(alert_rules) == 4 and all(r["health"] == "ok" for r in alert_rules)
    print("Prometheus: all 4 alert rules loaded and healthy")


if __name__ == "__main__":
    main()
