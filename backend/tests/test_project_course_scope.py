"""作品课程归属和教师审核权限回归测试。"""

from app.core.security import get_password_hash
from app.models.entities import Class, Course, Project, StudentClassEnrollment, User
from tests.conftest import auth_header


def _login(client, user_id: str, password: str = "abc123") -> str:
    return client.post("/api/token", json={"id": user_id, "password": password}).json()["data"]["access_token"]


def _create_project(client, token: str, course_id: int, title: str = "课程作品") -> int:
    resp = client.post(
        "/api/projects",
        json={
            "course_id": course_id,
            "title": title,
            "description": "作品说明",
            "tags": ["AI"],
            "image_urls": [],
            "image_file_ids": [],
        },
        headers=auth_header(token),
    ).json()
    assert resp["code"] == 0
    return resp["data"]["id"]


def test_student_must_submit_project_to_enrolled_course(client, db_session, student_token):
    other_course = db_session.query(Course).filter(Course.created_by == "T002").first()

    resp = client.post(
        "/api/projects",
        json={
            "course_id": other_course.id,
            "title": "越权课程作品",
            "description": "作品说明",
            "tags": [],
        },
        headers=auth_header(student_token),
    ).json()

    assert resp["code"] == 403
    assert "只能选择自己已加入的课程" in resp["message"]


def test_project_create_persists_course_and_returns_course_name(client, db_session, student_token):
    course = db_session.query(Course).filter(Course.created_by == "T001").first()
    project_id = _create_project(client, student_token, course.id)

    detail = client.get(f"/api/projects/{project_id}", headers=auth_header(student_token)).json()

    assert detail["code"] == 0
    assert detail["data"]["course_id"] == course.id
    assert detail["data"]["course_name"] == course.name


def test_project_resubmit_can_set_course_for_legacy_rejected_project(client, db_session, student_token):
    course = db_session.query(Course).filter(Course.created_by == "T001").first()
    legacy = Project(
        title="旧作品",
        author_id="2025001",
        description="旧作品说明",
        status="rejected",
        reject_reason="补充课程",
    )
    db_session.add(legacy)
    db_session.commit()

    resp = client.put(
        f"/api/projects/{legacy.id}",
        json={
            "course_id": course.id,
            "title": "旧作品重新提交",
            "description": "补充课程后重新提交",
            "tags": [],
            "image_urls": [],
            "image_file_ids": [],
        },
        headers=auth_header(student_token),
    ).json()
    db_session.refresh(legacy)

    assert resp["code"] == 0
    assert legacy.status == "pending"
    assert legacy.course_id == course.id


def test_teacher_only_lists_projects_in_own_course_scope(client, db_session, student_token, teacher_token):
    own_course = db_session.query(Course).filter(Course.created_by == "T001").first()
    own_project_id = _create_project(client, student_token, own_course.id, "本教师课程作品")

    other_student = User(
        id="2025999",
        name="其他教师学生",
        hashed_password=get_password_hash("abc123"),
        role="student",
        major="人工智能",
    )
    db_session.add(other_student)
    other_course = db_session.query(Course).filter(Course.created_by == "T002").first()
    other_class = db_session.query(Class).filter(Class.course_id == other_course.id).first()
    db_session.add(StudentClassEnrollment(user_id=other_student.id, class_id=other_class.id))
    db_session.add(Project(title="其他教师课程作品", author_id=other_student.id, course_id=other_course.id, status="pending"))
    db_session.commit()

    resp = client.get("/api/teacher/projects", headers=auth_header(teacher_token)).json()
    ids = [item["id"] for item in resp["data"]["items"]]

    assert resp["code"] == 0
    assert own_project_id in ids
    assert len(ids) == 1


def test_other_teacher_cannot_approve_reject_or_delete_project_outside_scope(client, db_session, student_token):
    course = db_session.query(Course).filter(Course.created_by == "T001").first()
    project_id = _create_project(client, student_token, course.id, "不可越权审核")
    other_teacher_token = _login(client, "T002")

    approve = client.post(
        f"/api/teacher/projects/{project_id}/approve",
        headers=auth_header(other_teacher_token),
    ).json()
    reject = client.post(
        f"/api/teacher/projects/{project_id}/reject",
        json={"reason": "越权驳回"},
        headers=auth_header(other_teacher_token),
    ).json()
    delete = client.delete(
        f"/api/teacher/projects/{project_id}",
        headers=auth_header(other_teacher_token),
    ).json()
    project = db_session.query(Project).filter(Project.id == project_id).one()

    assert approve["code"] == 404
    assert reject["code"] == 404
    assert delete["code"] == 404
    assert project.status == "pending"


def test_owner_teacher_can_approve_project_in_course_scope(client, db_session, student_token, teacher_token):
    course = db_session.query(Course).filter(Course.created_by == "T001").first()
    project_id = _create_project(client, student_token, course.id, "可审核作品")

    resp = client.post(
        f"/api/teacher/projects/{project_id}/approve",
        headers=auth_header(teacher_token),
    ).json()
    project = db_session.query(Project).filter(Project.id == project_id).one()

    assert resp["code"] == 0
    assert project.status == "approved"
