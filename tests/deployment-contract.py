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


if __name__ == "__main__":
    unittest.main()
