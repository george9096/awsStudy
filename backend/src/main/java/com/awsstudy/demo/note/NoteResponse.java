package com.awsstudy.demo.note;

import java.time.OffsetDateTime;

/**
 * 노트 응답 DTO.
 * 컨트롤러가 내보내는 출력 전용 객체 — 엔티티를 그대로 노출하지 않는다.
 */
public record NoteResponse(Long id, String content, OffsetDateTime createdAt) {

    // 엔티티(Note) → 응답 DTO 변환용 팩토리 메서드
    public static NoteResponse from(Note note) {
        return new NoteResponse(note.getId(), note.getContent(), note.getCreatedAt());
    }
}
