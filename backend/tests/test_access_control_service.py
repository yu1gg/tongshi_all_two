"""课程访问权限服务测试。"""

from app.services.access_control_service import student_can_access_course


def test_student_can_access_joined_course(db_session):
    assert student_can_access_course(db_session, "2025001", 1) is True


def test_student_cannot_access_unjoined_course(db_session):
    assert student_can_access_course(db_session, "2025001", 2) is False
