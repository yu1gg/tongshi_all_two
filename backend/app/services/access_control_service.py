"""访问权限辅助服务。"""

from sqlalchemy.orm import Session

from app.models.entities import Class, StudentClassEnrollment


def student_can_access_course(db: Session, user_id: str, course_id: int) -> bool:
    """判断学生是否加入了课程对应的任一班级。"""
    return db.query(StudentClassEnrollment.id).join(
        Class,
        Class.id == StudentClassEnrollment.class_id,
    ).filter(
        StudentClassEnrollment.user_id == user_id,
        Class.course_id == course_id,
    ).first() is not None
