#!/usr/bin/env python3
"""Offline regression checks for the pinned release's deployment boundaries."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def unit(name):
    values = {}
    for line in (ROOT / "quadlet" / name).read_text().splitlines():
        if line and not line.startswith(("#", "[")) and "=" in line:
            key, value = line.split("=", 1)
            values.setdefault(key, []).append(value)
    return values


class DeploymentContract(unittest.TestCase):
    def test_artifact_host_has_only_internal_database_and_ingress_networks(self):
        artifact_network = unit("artifactflow-artifact.network")
        self.assertEqual(artifact_network["Driver"], ["bridge"])
        self.assertEqual(artifact_network["Internal"], ["true"])
        self.assertEqual(artifact_network["NetworkName"], ["artifactflow-artifact"])
        ingress_network = unit("artifactflow-artifact-ingress.network")
        self.assertEqual(ingress_network["Driver"], ["bridge"])
        self.assertEqual(ingress_network["Internal"], ["true"])
        self.assertEqual(ingress_network["NetworkName"], ["artifactflow-artifact-ingress"])

        artifact_host = unit("artifactflow-artifact-host.container")
        self.assertEqual(set(artifact_host["Network"]),
                         {"artifactflow-artifact.network", "artifactflow-artifact-ingress.network"})
        self.assertNotIn("PublishPort", artifact_host)
        self.assertEqual(artifact_host["Sysctl"], ["net.ipv4.ip_forward=0"])
        self.assertEqual(set(unit("artifactflow-postgres.container")["Network"]),
                         {"artifactflow.network", "artifactflow-artifact.network"})
        for role in ("app", "worker", "scheduler", "reverb"):
            self.assertEqual(unit(f"artifactflow-{role}.container")["Network"],
                             ["artifactflow.network"])

    def test_artifact_origin_is_published_only_by_credential_free_relay(self):
        edge_network = unit("artifactflow-edge.network")
        self.assertEqual(edge_network["Driver"], ["bridge"])
        self.assertNotIn("Internal", edge_network)
        self.assertEqual(edge_network["NetworkName"], ["artifactflow-edge"])

        relay = unit("artifactflow-artifact-ingress.container")
        self.assertEqual(relay["Image"], ["localhost/artifactflow-image-parser:pinned"])
        self.assertEqual(relay["Pull"], ["never"])
        self.assertEqual(relay["Entrypoint"], ["/usr/bin/socat"])
        self.assertEqual(relay["Exec"], ["TCP4-LISTEN:8081,bind=0.0.0.0,reuseaddr,fork "
                                         "TCP4:artifactflow-artifact-host:8081"])
        self.assertEqual(relay["Network"],
                         ["artifactflow-edge.network", "artifactflow-artifact-ingress.network"])
        self.assertEqual(relay["PublishPort"], ["127.0.0.1:8081:8081"])
        self.assertNotIn("Volume", relay)
        self.assertNotIn("EnvironmentFile", relay)
        self.assertNotIn("Environment", relay)
        self.assertEqual(relay["User"], ["10001:10001"])
        self.assertEqual(relay["ReadOnly"], ["true"])
        self.assertEqual(relay["DropCapability"], ["ALL"])
        self.assertEqual(relay["Sysctl"], ["net.ipv4.ip_forward=0"])
        self.assertEqual(relay["NoNewPrivileges"], ["true"])
        self.assertIn("socat", relay["HealthCmd"][0])
        self.assertIn("artifactflow-artifact-host:8081", relay["Exec"][0])
        self.assertNotIn("healthcheck.php", relay["HealthCmd"][0])
        self.assertIn("[234]", relay["HealthCmd"][0])
        self.assertIn("artifactflow-artifact-host.service", relay["Requires"])

    def test_app_can_connect_to_private_document_sockets(self):
        app = unit("artifactflow-app.container")
        for gid in ("10002", "10003", "10004"):
            self.assertIn(gid, app.get("GroupAdd", []))

    def test_image_parser_uses_release_required_socket_transport(self):
        parser = unit("artifactflow-image-parser.container")
        self.assertEqual(parser["Network"], ["none"])
        self.assertIn("artifactflow-image-socket:/run/artifactflow/image-parser:ro",
                      unit("artifactflow-app.container")["Volume"])
        self.assertIn("IMAGE_PARSER_SOCKET_PATH=/run/artifactflow/image-parser/parser.sock",
                      (ROOT / "env/app.env.example").read_text())
        for role in ("artifact-host", "worker", "scheduler"):
            self.assertIn("IMAGE_PARSER_SOCKET_PATH=", " ".join(
                unit(f"artifactflow-{role}.container")["Environment"]))

    def test_pdf_transport_adapter_is_built_instead_of_retagging_tcp_image(self):
        adapter = ROOT / "Dockerfile.pdf-processor"
        self.assertTrue(adapter.exists(), "Published PDF image has no Unix listener")
        contents = adapter.read_text()
        self.assertIn("ENTRYPOINT []", contents)
        self.assertIn("pdf-processor-spike/start.sh", contents)
        self.assertIn("pdf-processor-spike/healthcheck.php", contents)
        for script in ("install.sh", "deploy.sh"):
            self.assertIn("-f Dockerfile.pdf-processor", (ROOT / script).read_text())

    def test_office_pid_budget_includes_health_process_and_child_worker(self):
        self.assertEqual(unit("artifactflow-xlsx-processor.container")["PidsLimit"], ["32"])

    def test_installer_reloads_existing_containers_before_doctor(self):
        contents = (ROOT / "install.sh").read_text()
        doctor = contents.index("podman exec artifactflow-app sh -c 'cd /var/www/html && php artisan artifactflow:doctor'")
        for name in ("app", "artifact-host", "pdf-processor", "xlsx-processor", "docx-processor"):
            self.assertIn(f"systemctl --user restart artifactflow-{name}", contents[:doctor])

    def test_deploy_checks_live_processor_chain(self):
        self.assertIn("php artisan artifactflow:doctor", (ROOT / "deploy.sh").read_text())

    def test_socket_initializers_have_explicit_entrypoint(self):
        for path in (ROOT / "quadlet").glob("*-socket-init.container"):
            self.assertEqual(unit(path.name).get("Entrypoint"), ["/bin/sh"], path.name)

    def test_reverb_is_worker_role_loopback_only_and_isolated_from_artifact_host(self):
        reverb = unit("artifactflow-reverb.container")
        env = " ".join(reverb["Environment"])
        self.assertIn("APP_RUNTIME_ROLE=worker", env)
        self.assertIn("reverb:start", " ".join(reverb["Exec"]))
        self.assertEqual(reverb["PublishPort"], ["127.0.0.1:8082:8080"])
        # The reverb worker carries no parser/processor credentials.
        for absent in ("IMAGE_PARSER_SHARED_SECRET=", "PDF_PROCESSOR_SHARED_SECRET="):
            self.assertIn(absent, env)
        # The artifact origin never receives realtime egress or the reverb secret.
        artifact_host = " ".join(unit("artifactflow-artifact-host.container")["Environment"])
        self.assertIn("BROADCAST_CONNECTION=null", artifact_host)
        self.assertIn("REVERB_APP_SECRET=", artifact_host)


if __name__ == "__main__":
    unittest.main()
