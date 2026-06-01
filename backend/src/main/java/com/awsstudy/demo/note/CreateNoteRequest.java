package com.awsstudy.demo.note;

/**
 * 노트 생성 요청 DTO.
 * 컨트롤러가 받는 입력 전용 객체 — 엔티티(Note)를 직접 받지 않는다.
 */
public record CreateNoteRequest(String content) {
}
