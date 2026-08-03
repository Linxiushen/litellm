"""
Accumulates gateway request counts (SGR) recorded at the ASGI edge and commits
them to ``LiteLLM_DailyGatewayRequests``.

Unlike the spend queues this keeps no per-request item. A count is a pure
aggregate, so requests fold into an in-memory map as they finish. The map is
bounded by (classified route x model_id) cardinality rather than by request
volume: the route classifier returns one of a fixed set of strings, never the
raw path. That keeps the response path free of an unbounded queue that would
block once full.
"""

from datetime import datetime, timezone
from typing import TYPE_CHECKING

from litellm._logging import verbose_proxy_logger
from litellm.proxy.middleware.billable_request_metrics_middleware import BillableCategory
from litellm.types.proxy.gateway_requests import (
    GatewayRequestCounts,
    GatewayRequestKey,
    GatewayRequestSnapshot,
)

if TYPE_CHECKING:
    from litellm.proxy.utils import PrismaClient

_EMPTY = GatewayRequestCounts(successful_requests=0, failed_requests=0)


def _utc_date() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


class GatewayRequestAccumulator:
    """Sink for the request-metrics middleware. ``record`` is sync and never awaits."""

    def __init__(self) -> None:
        self._counts: dict[GatewayRequestKey, GatewayRequestCounts] = {}  # mutable-ok: bounded fold, drained per flush

    def record(self, *, category: BillableCategory, route: str, status_code: int, model_id: str | None) -> None:
        key = GatewayRequestKey(
            date=_utc_date(),
            category=category.value,
            route=route,
            model_id=model_id or "",
        )
        self._counts[key] = self._counts.get(key, _EMPTY).plus(succeeded=200 <= status_code < 300)

    def drain(self) -> GatewayRequestSnapshot:
        drained = self._counts
        self._counts = {}
        return drained

    def restore(self, snapshot: GatewayRequestSnapshot) -> None:
        """
        Merge un-committed counts back so the next flush retries them.

        A dropped flush would silently undercount the metric the dashboard now
        treats as the source of truth. Merging cannot grow without bound: keys
        collapse on collision, so the fold stays bounded by
        (route x model_id x date) however long the database is unreachable.
        """
        for key, counts in snapshot.items():
            existing = self._counts.get(key, _EMPTY)
            self._counts[key] = GatewayRequestCounts(
                successful_requests=existing.successful_requests + counts.successful_requests,
                failed_requests=existing.failed_requests + counts.failed_requests,
            )


async def commit_gateway_requests_to_db(
    *,
    prisma_client: "PrismaClient",
    snapshot: GatewayRequestSnapshot,
) -> None:
    """Upsert one incrementing row per (date, category, route, model_id)."""
    if not snapshot:
        return

    ordered = sorted(
        snapshot.items(),
        key=lambda item: (item[0].date, item[0].category, item[0].route, item[0].model_id),
    )

    # pyright: ignore[reportAny] on both lines -- prisma's generated client is untyped,
    # so .db and every table action off it resolve to Any at this boundary.
    async with prisma_client.db.batch_() as batcher:  # pyright: ignore[reportAny]  # untyped prisma client
        for key, counts in ordered:
            batcher.litellm_dailygatewayrequests.upsert(  # pyright: ignore[reportAny]  # untyped prisma client
                where={
                    "date_category_route_model_id": {
                        "date": key.date,
                        "category": key.category,
                        "route": key.route,
                        "model_id": key.model_id,
                    }
                },
                data={
                    "create": {
                        "date": key.date,
                        "category": key.category,
                        "route": key.route,
                        "model_id": key.model_id,
                        "successful_requests": counts.successful_requests,
                        "failed_requests": counts.failed_requests,
                    },
                    "update": {
                        "successful_requests": {"increment": counts.successful_requests},
                        "failed_requests": {"increment": counts.failed_requests},
                    },
                },
            )

    verbose_proxy_logger.debug("Gateway request tracking - committed %d aggregated rows", len(ordered))


async def flush_gateway_requests(
    prisma_client: "PrismaClient",
    accumulator: GatewayRequestAccumulator,
) -> None:
    """Scheduler entrypoint. Never raises: a metering failure must not kill the job."""
    snapshot = accumulator.drain()
    try:
        await commit_gateway_requests_to_db(prisma_client=prisma_client, snapshot=snapshot)
    except Exception:  # noqa: BLE001 -- a failed flush must not stop the scheduler
        accumulator.restore(snapshot)
        verbose_proxy_logger.warning(
            "Gateway request tracking - failed to commit %d rows, retrying on the next flush",
            len(snapshot),
            exc_info=True,
        )
