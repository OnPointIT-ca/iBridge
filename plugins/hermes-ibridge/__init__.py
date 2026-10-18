"""Native Hermes plugin; importing and registering never makes network calls."""

from . import tools


def register(ctx):
    ctx.register_tool(
        name="ibridge_capabilities",
        toolset="ibridge",
        schema={
            "name": "ibridge_capabilities",
            "description": (
                "Check which Apple-service operations your remote Mac currently "
                "allows through iBridge. Unavailable services are not empty results."
            ),
            "parameters": {"type": "object", "properties": {}, "additionalProperties": False},
        },
        handler=tools.capabilities,
        requires_env=["IBRIDGE_URL", "IBRIDGE_TOKEN"],
    )
