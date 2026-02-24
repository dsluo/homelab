from pathlib import Path

from copier_template_extensions import ContextHook


class NamespacesHook(ContextHook):
    def hook(self, context):
        dst = Path(context["_copier_conf"]["dst_path"])
        apps_dir = dst / "kubernetes" / "apps"
        namespaces = []
        if apps_dir.exists():
            namespaces = sorted(d.name for d in apps_dir.iterdir() if d.is_dir())
        return {"existing_namespaces": namespaces}
