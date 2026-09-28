//
//  OnChangeCompat.swift
//  TriClean
//
//  배포 타깃은 macOS 13.5다. `onChange(of:initial:_:)`(인자 0개·2개 클로저)는
//  macOS 14부터라 그대로 쓰면 빌드가 되지 않고, 1인자 `onChange(of:perform:)`는
//  14에서 deprecated다. 14 이상에서는 새 API를, 13에서는 기존 API를 쓰도록 감싼다.
//

import SwiftUI

extension View {
    /// 값이 바뀌었을 때 새 값으로 `action`을 호출한다. (초기값에는 호출하지 않음)
    @ViewBuilder
    func onValueChange<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        if #available(macOS 14.0, *) {
            self.onChange(of: value) { _, newValue in action(newValue) }
        } else {
            self.onChange(of: value, perform: action)
        }
    }
}
