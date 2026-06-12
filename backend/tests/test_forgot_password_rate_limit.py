"""忘记密码限流内存清理测试。"""

from datetime import datetime, timedelta, timezone

from app.services import auth_service


def test_forgot_failure_cleanup_removes_expired_users():
    now = datetime(2026, 6, 11, tzinfo=timezone.utc)
    old = now - timedelta(minutes=auth_service._ATTEMPT_WINDOW_MINUTES + 1)
    fresh = now - timedelta(minutes=1)

    auth_service._FORGOT_FAILURES.clear()
    auth_service._FORGOT_FAILURES["old-user"] = [old]
    auth_service._FORGOT_FAILURES["fresh-user"] = [fresh]

    auth_service._cleanup_forgot_failures(now)

    assert "old-user" not in auth_service._FORGOT_FAILURES
    assert auth_service._FORGOT_FAILURES["fresh-user"] == [fresh]
