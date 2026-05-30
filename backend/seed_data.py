"""Seed data for the tongshi AI course platform"""
from datetime import datetime, timedelta, timezone

from app.core.security import get_password_hash
from app.db.session import SessionLocal
from app.models.entities import User


def seed():
    db = SessionLocal()

    # 创建默认管理员账号（若不存在）
    admin_user = db.query(User).filter(User.id == "admin").first()
    if not admin_user:
        admin = User(
            id="admin",
            name="系统管理员",
            role="admin",
            hashed_password=get_password_hash("admin123456"),
            needs_password_change=False,
        )
        db.add(admin)
        db.commit()
        print("已创建默认管理员账号: admin / admin123456")
    else:
        print("  管理员账号已存在，跳过")

    db.close()
    print("Seed complete!")


if __name__ == "__main__":
    seed()
